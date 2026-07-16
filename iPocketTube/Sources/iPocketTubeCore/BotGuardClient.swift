import Foundation
import JavaScriptCore
import os
import CryptoKit

// MARK: - BotGuardError

public enum BotGuardError: Error, CustomStringConvertible {
    case challengeFailed(String)
    case challengeParseError(String)
    case jsFailed(String)
    case integrityTokenFailed(String)
    case mintFailed(String)

    public var description: String {
        switch self {
        case .challengeFailed(let m):       "BotGuard challenge fetch failed: \(m)"
        case .challengeParseError(let m):   "BotGuard challenge parse error: \(m)"
        case .jsFailed(let m):              "BotGuard JS error: \(m)"
        case .integrityTokenFailed(let m):  "BotGuard integrity token failed: \(m)"
        case .mintFailed(let m):            "BotGuard mint failed: \(m)"
        }
    }
}

// MARK: - BotGuardClient

/// Generates YouTube Proof-of-Origin (PO) tokens on-device using JavaScriptCore.
///
/// The BotGuard attestation pipeline mirrors https://github.com/LuanRT/BgUtils (MIT):
/// 1. Fetch the BotGuard challenge (interpreter JS + program + globalName) from Google's WAA API.
/// 2. Execute the interpreter JS in a `JSContext`; call `vm.a(program, callback, …)` to load the program.
/// 3. Call `asyncSnapshotFn(callback, params)` → `botguardResponse` string.
/// 4. POST `botguardResponse` to WAA GenerateIT → `integrityTokenB64`.
/// 5. Call `webPoSignalOutput[0](integrityTokenBytes)` → minter → call minter with videoId bytes → base64 token.
///
/// All JSContext work and blocking network calls run on a dedicated serial `jsQueue` (a real OS thread).
/// Network calls use `URLSession.dataTask` + `DispatchSemaphore` — safe because `jsQueue` is not part of
/// Swift's cooperative concurrency thread pool.
public final class BotGuardClient: PoTokenProvider, @unchecked Sendable {

    // MARK: - WAA API constants
    // Public API key used by YouTube's web client; from BgUtils / YouTube JS source.
    private static let waaAPIKey  = "AIzaSyDyT5W0Jh49F30Pqqtyfdf7pDLFKLJoAnw"
    // YouTube BotGuard request key (stable; from BgUtils examples).
    private static let requestKey = "O43z0dpjhgX20SCx4KAo"
    private static let waaCreateURL     = URL(string: "https://jnn-pa.googleapis.com/$rpc/google.internal.waa.v1.Waa/Create")!
    private static let waaGenerateITURL = URL(string: "https://jnn-pa.googleapis.com/$rpc/google.internal.waa.v1.Waa/GenerateIT")!

    // MARK: - Properties
    private let session: URLSession
    private let bgLog = Logger(subsystem: appSubsystem, category: "BotGuard")
    /// All JSContext access serialised on this queue. It is a real OS thread, so
    /// `DispatchSemaphore.wait()` inside blocks here does NOT block the Swift cooperative pool.
    private let jsQueue = DispatchQueue(label: "st.botguard.js", qos: .userInitiated)

    // MARK: - PO token cache
    // The websafeFallbackToken from GenerateIT is a generic attestation — not video-specific
    // — so it can be reused across sequential video loads within its TTL window.
    // nonisolated(unsafe): BotGuardClient is @unchecked Sendable; token() is awaited
    // sequentially per video so concurrent mutation is benign in practice.
    nonisolated(unsafe) private var cachedPoToken: String?
    nonisolated(unsafe) private var cachedPoTokenExpiry: Date?

    /// Set at the end of mintSync so callers can inspect which path was taken after await token(for:).
    nonisolated(unsafe) public private(set) var lastRunHasMinter: Bool = false
    nonisolated(unsafe) public private(set) var lastRunIntegrityTokenLen: Int = 0

    // MARK: - Init

    public init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - PoTokenProvider

    public func token(for videoId: String) async throws -> String {
        // Return cached token if still valid — websafeFallbackToken from GenerateIT is
        // not video-specific so it can be reused across sequential video loads.
        if !DebugFlags.cachingDisabled,
           let cached = cachedPoToken, let expiry = cachedPoTokenExpiry, Date() < expiry {
            let ttlRemaining = Int(expiry.timeIntervalSinceNow)
            bgLog.notice("[BotGuard] ✅ cached PO token (ttl=\(ttlRemaining, privacy: .public)s) for \(videoId, privacy: .public)")
            return cached
        }

        bgLog.notice("[BotGuard] token requested for \(videoId, privacy: .public)")

        // Phase 1 – fetch challenge (async Swift network call, off jsQueue).
        let challenge = try await fetchChallenge()
        bgLog.notice("[BotGuard] challenge ok, globalName=\(challenge.globalName, privacy: .public) jsLen=\(challenge.interpreterJS.count)")

        // Phase 2–5 – run entirely on jsQueue to keep all JSValue references on one thread.
        let (token, ttl) = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(String, Int), Error>) in
            jsQueue.async {
                do {
                    let result = try self.runPipelineSync(challenge: challenge, videoId: videoId)
                    cont.resume(returning: result)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }

        // Cache for reuse within the TTL window.
        cachedPoToken = token
        cachedPoTokenExpiry = Date().addingTimeInterval(TimeInterval(ttl > 0 ? ttl : 3600))

        bgLog.notice("[BotGuard] ✅ PO token minted (len=\(token.count), ttl=\(ttl)s) for \(videoId, privacy: .public)")
        return token
    }

    // MARK: - Challenge model

    private struct BotGuardChallenge {
        let interpreterJS: String
        let program: String
        let globalName: String
    }

    // MARK: - Phase 1: fetch challenge from WAA Create endpoint

    private func fetchChallenge() async throws -> BotGuardChallenge {
        var req = URLRequest(url: Self.waaCreateURL, timeoutInterval: 12)
        req.httpMethod = "POST"
        req.setValue("application/json+protobuf", forHTTPHeaderField: "Content-Type")
        req.setValue(Self.waaAPIKey,              forHTTPHeaderField: "x-goog-api-key")
        req.setValue("grpc-web-javascript/0.1",   forHTTPHeaderField: "x-user-agent")
        req.httpBody = try JSONSerialization.data(withJSONObject: [Self.requestKey])

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw BotGuardError.challengeFailed("HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }

        // Log raw response for parse debugging (truncated to 300 chars)
        let rawPreview = String(data: data, encoding: .utf8).map { String($0.prefix(300)) } ?? "<binary>"
        bgLog.notice("[BotGuard] WAA Create raw response (first 300): \(rawPreview, privacy: .public)")

        guard let outer = try? JSONSerialization.jsonObject(with: data) as? [Any],
              outer.count >= 2 else {
            throw BotGuardError.challengeParseError("outer array missing")
        }
        bgLog.notice("[BotGuard] outer array count=\(outer.count)")

        // Current WAA Create format (BgUtils v3.2+): outer[1] is a scrambled base64 string.
        // Scrambling: each byte of the UTF-8 inner JSON had 97 subtracted (mod 256).
        // Descrambling: base64-decode → add 97 to every byte (mod 256) → UTF-8 → JSON-parse.
        if let scrambled = outer[1] as? String, !scrambled.isEmpty {
            bgLog.notice("[BotGuard] outer[1] is String len=\(scrambled.count) — descrambling (BgUtils v3.2 format)")
            do {
                return try await descrambleAndParse(scrambled)
            } catch {
                bgLog.notice("[BotGuard] descramble failed: \(error) — falling back")
            }
        }

        // Legacy format: outer[0] is the inner challenge array directly.
        if let candidate = outer[0] as? [Any], candidate.count >= 5 {
            bgLog.notice("[BotGuard] outer[0] is array (legacy format) — trying inner parse")
            do {
                return try await parseInnerArray(candidate)
            } catch {
                bgLog.notice("[BotGuard] legacy inner parse failed: \(error) — falling back")
            }
        }

        // Last resort: fetch interpreter from YouTube homepage player JS.
        bgLog.notice("[BotGuard] all parse strategies failed — fetching interpreter from YouTube homepage")
        let js = try await fetchInterpreterFromYouTube()
        return BotGuardChallenge(interpreterJS: js, program: "", globalName: "")
    }

    /// Descrambles a WAA Create scrambled challenge string and parses the resulting inner JSON array.
    ///
    /// The WAA API (BgUtils v3.2+) encodes the challenge data as follows:
    /// 1. Inner challenge array → UTF-8 JSON
    /// 2. Each byte `b` → `(b - 97) mod 256`  (subtract 97, wrapping)
    /// 3. Result → base64-encoded string stored as `outer[1]`
    ///
    /// To descramble: base64-decode → `map { $0 &+ 97 }` → UTF-8-decode → JSON-parse.
    private func descrambleAndParse(_ scrambled: String) async throws -> BotGuardChallenge {
        // Restore standard base64 padding (WAA response omits trailing '=')
        let rem = scrambled.count % 4
        let padded = rem == 0 ? scrambled : scrambled + String(repeating: "=", count: 4 - rem)
        guard let encoded = Data(base64Encoded: padded, options: .ignoreUnknownCharacters) else {
            throw BotGuardError.challengeParseError("descramble: base64 decode failed (len=\(scrambled.count))")
        }
        // Add 97 to each byte with wrapping arithmetic — mirrors JS: Uint8Array b + 97
        let descrambled = Data(encoded.map { $0 &+ 97 })
        guard let json = String(data: descrambled, encoding: .utf8) else {
            throw BotGuardError.challengeParseError("descramble: UTF-8 decode failed after unshift")
        }
        bgLog.notice("[BotGuard] descrambled JSON (first 200): \(String(json.prefix(200)), privacy: .public)")
        guard let inner = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [Any] else {
            throw BotGuardError.challengeParseError("descramble: inner JSON parse failed")
        }
        return try await parseInnerArray(inner)
    }

    /// Parses the inner BotGuard challenge array (after descrambling).
    ///
    /// Expected layout from BgUtils `DescrambledChallenge`:
    /// ```
    /// [ messageId, wrappedScript, wrappedUrl, interpreterHash, program, globalName, ?, clientExperimentsStateBlob ]
    /// ```
    /// - `wrappedScript` (`inner[1]`): `[Any]` — first non-empty `String` is inline VM JS
    /// - `wrappedUrl`    (`inner[2]`): `[Any]` — first non-empty `String` is URL to fetch VM JS from
    /// - `program`       (`inner[4]`): `String`
    /// - `globalName`    (`inner[5]`): `String`
    private func parseInnerArray(_ inner: [Any]) async throws -> BotGuardChallenge {
        guard inner.count >= 6 else {
            throw BotGuardError.challengeParseError("inner array too short (\(inner.count), need ≥6)")
        }
        let wrappedScript = inner[1] as? [Any] ?? []
        let wrappedUrl    = inner[2] as? [Any] ?? []
        let program       = inner[4] as? String ?? ""
        let globalName    = inner[5] as? String ?? ""
        guard !program.isEmpty else {
            throw BotGuardError.challengeParseError("program empty at inner[4]")
        }
        bgLog.notice("[BotGuard] inner parse: globalName='\(globalName, privacy: .public)' programLen=\(program.count)")

        // Prefer inline JS from wrappedScript (avoids extra network round-trip)
        if let inlineJS = wrappedScript.compactMap({ $0 as? String }).first(where: { !$0.isEmpty }) {
            bgLog.notice("[BotGuard] using inline interpreter JS from wrappedScript (len=\(inlineJS.count))")
            return BotGuardChallenge(interpreterJS: inlineJS, program: program, globalName: globalName)
        }

        // Fall back to fetching interpreter JS from URL in wrappedUrl
        if let urlRaw = wrappedUrl.compactMap({ $0 as? String }).first(where: { !$0.isEmpty }) {
            bgLog.notice("[BotGuard] fetching interpreter JS from wrappedUrl: \(String(urlRaw.prefix(80)), privacy: .public)")
            let js = try await fetchInterpreterJS(from: urlRaw)
            return BotGuardChallenge(interpreterJS: js, program: program, globalName: globalName)
        }

        throw BotGuardError.challengeParseError("no interpreter JS source in wrappedScript or wrappedUrl")
    }

    /// Fetches interpreter JS from a URL, or returns `raw` directly if it is inline JS.
    private func fetchInterpreterJS(from raw: String) async throws -> String {
        let urlStr = raw.hasPrefix("//") ? "https:\(raw)" : raw
        if let jsURL = URL(string: urlStr), jsURL.scheme != nil, jsURL.host != nil {
            let (jsData, _) = try await session.data(from: jsURL)
            let js = String(data: jsData, encoding: .utf8) ?? ""
            bgLog.notice("[BotGuard] interpreter JS fetched from URL (len=\(js.count))")
            return js
        }
        return raw  // raw is inline JS
    }

    /// Fetches YouTube's current player JS by extracting the player URL from the homepage.
    /// Used as a fallback when the WAA Create binary proto parse cannot provide an interpreter URL.
    private func fetchInterpreterFromYouTube() async throws -> String {
        bgLog.notice("[BotGuard] fetching interpreter URL from YouTube homepage")
        guard let homeURL = URL(string: "https://www.youtube.com/") else {
            throw BotGuardError.challengeParseError("YouTube homepage: invalid URL")
        }
        var homeReq = URLRequest(url: homeURL, timeoutInterval: 12)
        homeReq.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/15.5 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        let (htmlData, _) = try await session.data(for: homeReq)
        guard let html = String(data: htmlData, encoding: .utf8) else {
            throw BotGuardError.challengeParseError("YouTube homepage: invalid UTF-8")
        }
        // Match the player JS path: /s/player/<hash>/player_ias.vflset/<locale>/base.js
        let patterns = [
            #"["'](/s/player/[a-f0-9]+/player_ias\.vflset/[^"'/]+/base\.js)["']"#,
            #"src\s*=\s*["']([^"']*player[^"']*\.js)["']"#,
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
               let range = Range(match.range(at: 1), in: html) {
                let path = String(html[range])
                let fullURL: String
                if path.hasPrefix("//")   { fullURL = "https:\(path)" }
                else if path.hasPrefix("http") { fullURL = path }
                else                       { fullURL = "https://www.youtube.com\(path)" }
                bgLog.notice("[BotGuard] player JS URL: \(String(fullURL.prefix(80)), privacy: .public)")
                return try await fetchInterpreterJS(from: fullURL)
            }
        }
        throw BotGuardError.challengeParseError("YouTube homepage: player JS URL not found in HTML")
    }

    // MARK: - Binary Protobuf Helpers

    /// Reads a protobuf varint from `bytes` starting at `pos`.
    /// Returns (value, next_position) or nil on parse error / truncated input.
    private static func readVarint(from bytes: [UInt8], at pos: Int) -> (UInt64, Int)? {
        var result: UInt64 = 0
        var shift = 0
        var idx = pos
        while idx < bytes.count {
            let b = bytes[idx]; idx += 1
            result |= UInt64(b & 0x7F) << shift
            shift += 7
            if b & 0x80 == 0 { return (result, idx) }
            if shift >= 64 { return nil }
        }
        return nil
    }

    /// Parses a binary protobuf blob and returns a dict of `fieldNumber → raw Data`
    /// for every **length-delimited** (wire type 2) field encountered.
    /// Other wire types are skipped. Duplicate field numbers keep the last value.
    private static func readProtoFields(_ data: Data) -> [Int: Data] {
        let bytes = [UInt8](data)
        var pos = 0
        var fields: [Int: Data] = [:]

        while pos < bytes.count {
            guard let (tag, p1) = readVarint(from: bytes, at: pos) else { break }
            pos = p1
            let fieldNum = Int(tag >> 3)
            let wireType = Int(tag & 7)

            switch wireType {
            case 0:  // varint — skip
                guard let (_, p2) = readVarint(from: bytes, at: pos) else { return fields }
                pos = p2
            case 1:  // 64-bit — skip
                guard pos + 8 <= bytes.count else { return fields }
                pos += 8
            case 2:  // length-delimited — capture
                guard let (len, p2) = readVarint(from: bytes, at: pos) else { return fields }
                pos = p2
                let end = pos + Int(len)
                guard end <= bytes.count else { return fields }
                let startIdx = data.index(data.startIndex, offsetBy: pos)
                let endIdx   = data.index(data.startIndex, offsetBy: end)
                fields[fieldNum] = data[startIdx..<endIdx]
                pos = end
            case 3:  // start group (proto2, deprecated) — skip until matching end group
                let groupField = fieldNum
                var depth = 1
                groupLoop: while pos < bytes.count && depth > 0 {
                    guard let (innerTag, innerP) = readVarint(from: bytes, at: pos) else { break groupLoop }
                    pos = innerP
                    let iWire = Int(innerTag & 7)
                    let iField = Int(innerTag >> 3)
                    switch iWire {
                    case 0: guard let (_, p2) = readVarint(from: bytes, at: pos) else { break groupLoop }; pos = p2
                    case 1: guard pos + 8 <= bytes.count else { break groupLoop }; pos += 8
                    case 2:
                        guard let (len, p2) = readVarint(from: bytes, at: pos) else { break groupLoop }
                        pos = p2
                        guard pos + Int(len) <= bytes.count else { break groupLoop }
                        pos += Int(len)
                    case 3: depth += 1
                    case 4: if iField == groupField { depth -= 1 }
                    case 5: guard pos + 4 <= bytes.count else { break groupLoop }; pos += 4
                    default: break groupLoop
                    }
                }
            case 4:  // end group (unexpected at top level) — stop
                return fields
            case 5:  // 32-bit — skip
                guard pos + 4 <= bytes.count else { return fields }
                pos += 4
            default:
                return fields  // unknown wire type → stop parsing
            }
        }
        return fields
    }

    // MARK: - Phase 2–5: synchronous pipeline on jsQueue

    /// Runs the entire BotGuard pipeline synchronously:
    /// JS VM execution → integrity token fetch (blocking) → mint (JS).
    /// Must be called from `jsQueue` only.
    private func runPipelineSync(challenge: BotGuardChallenge, videoId: String) throws -> (token: String, ttl: Int) {

        // --- Set up JSContext with minimal polyfills ---
        guard let ctx = JSContext() else {
            throw BotGuardError.jsFailed("JSContext() returned nil")
        }
        ctx.exceptionHandler = { [weak self] _, exc in
            let msg     = exc?.toString() ?? "nil"
            let message = exc?.objectForKeyedSubscript("message")?.toString() ?? ""
            let line    = exc?.objectForKeyedSubscript("line")?.toInt32() ?? -1
            let col     = exc?.objectForKeyedSubscript("column")?.toInt32() ?? -1
            let src     = exc?.objectForKeyedSubscript("sourceURL")?.toString() ?? "<eval>"
            // Build detail as plain String to avoid OSLogMessage Substring/Int32 overload issues
            let detail  = "\(msg) | msg=\(message) | \(src):\(line):\(col)"
            self?.bgLog.warning("[BotGuard] JSContext exception: \(detail, privacy: .public)")
        }
        installPolyfills(ctx)

        // --- Load BotGuard interpreter VM ---
        ctx.evaluateScript(challenge.interpreterJS)
        if let exc = ctx.exception {
            throw BotGuardError.jsFailed("interpreter load: \(exc)")
        }
        // Re-install crypto.subtle after VM loading (VM may have overwritten window.crypto).
        ctx.evaluateScript("try { if (typeof __bgSubtle !== 'undefined') { if (typeof crypto === 'undefined') { var crypto = {}; } crypto.subtle = __bgSubtle; } } catch(e) {}")
        // Re-attach __bgLog to console.log — BotGuard's VM JS may have overwritten the console object.
        // __bgLog itself (a native JSC global) is unaffected since it's set via ctx.setObject.
        ctx.evaluateScript("try { if (typeof __bgLog !== 'undefined') { if (typeof console === 'undefined') { var console = {}; } console.log = __bgLog; console.warn = __bgLog; console.error = __bgLog; } } catch(e) {}")

        // --- Locate the VM object in global scope ---
        // When globalName is non-empty, look it up directly.
        // When empty (fallback path), discover the VM by scanning globals for an object
        // with a method 'a' — this is the BotGuard VM's known entry-point signature.
        var vm: JSValue?
        if !challenge.globalName.isEmpty {
            vm = ctx.globalObject?.objectForKeyedSubscript(challenge.globalName)
        }
        if vm == nil || vm!.isNull || vm!.isUndefined {
            let discovered = ctx.evaluateScript("""
                (function() {
                    var ks = Object.keys(globalThis);
                    for (var i = 0; i < ks.length; i++) {
                        var v = globalThis[ks[i]];
                        if (v && typeof v === 'object' && typeof v.a === 'function') return ks[i];
                    }
                    return null;
                })()
            """)
            if let name = discovered?.toString(), name != "null", !name.isEmpty {
                bgLog.notice("[BotGuard] discovered globalName=\(name, privacy: .public) (requested='\(challenge.globalName, privacy: .public)')")
                vm = ctx.globalObject?.objectForKeyedSubscript(name)
            }
        }
        guard let vm, !vm.isNull, !vm.isUndefined else {
            throw BotGuardError.jsFailed("VM '\(challenge.globalName)' not in JSContext global (dynamic discovery also failed)")
        }

        // --- Phase 2: call vm.a(program, vmFunctionsCallback, true, undefined, noop, [[], []]) ---
        var asyncSnapshotFn: JSValue?
        let vmFnCallback: @convention(block) (JSValue, JSValue, JSValue, JSValue) -> Void = { fn0, _, _, _ in
            // arg0 = integrityTokenBasedRequestKey — calls callback with snapshot response.
            // (webPoSignalOutput[0] is the getMinter factory; fallback to websafeFallbackToken when not set)
            asyncSnapshotFn = fn0
        }
        let undef    = JSValue(undefinedIn: ctx)!
        let noopFn   = JSValue(object: { } as @convention(block) () -> Void, in: ctx)!
        let initPair = ctx.evaluateScript("[[],[]]")!

        // invokeMethod sets this=vm, required by the real BotGuard VM's internal methods.
        let vmCallResult = vm.invokeMethod("a", withArguments: [
            challenge.program,
            JSValue(object: vmFnCallback, in: ctx)!,
            NSNumber(value: true),
            undef,
            noopFn,
            initPair
        ])

        if let exc = ctx.exception { throw BotGuardError.jsFailed("vm.a(): \(exc)") }

        // vm.a() may return [syncFn, ...] or [Promise, ...]; pump microtasks either way.
        if let initPromise = vmCallResult?.objectAtIndexedSubscript(0),
           initPromise.objectForKeyedSubscript("then")?.isObject == true {
            _ = try resolvePromise(initPromise, in: ctx, label: "vm.a() init")
        } else {
            pumpMicrotasks(ctx, count: 3)
        }

        guard let snapFn = asyncSnapshotFn, !snapFn.isNull, !snapFn.isUndefined else {
            throw BotGuardError.jsFailed("asyncSnapshotFn not set after vm.a() — VM may have changed API")
        }
        bgLog.notice("[BotGuard] Phase 2 ✅ VM loaded, asyncSnapshotFn set")

        // --- Phase 3: asyncSnapshotFn(callback, [undefined, undefined, webPoSignalOutput, undefined]) ---
        // webPoSignalOutput must be a named JS global so __bgSO in the snapArgs array
        // is a live reference to the same JS array object.  ctx.setObject(_:forKeyedSubscript:)
        // doesn't reliably set globals when passed a JSValue — create the array in JS instead.
        //
        // NOTE: The BotGuard VM interpreter CLONES function arguments before use, so Proxy
        // set-traps on webPoSignalOutput never fire from within the VM. getMinter (index 0)
        // is therefore never set; the websafe fallback token (json[3] from GenerateIT) is used.
        var botguardResponse: String?
        ctx.evaluateScript("var __bgSO = []")
        let webPoSignalOutput = ctx.globalObject.objectForKeyedSubscript("__bgSO")!
        let snapArgs = ctx.evaluateScript("[undefined, undefined, __bgSO, undefined]")!

        let snapCallback: @convention(block) (JSValue) -> Void = { arg0 in
            botguardResponse = arg0.isNull || arg0.isUndefined ? nil : arg0.toString()
        }
        if let exc = ctx.exception { throw BotGuardError.jsFailed("asyncSnapshotFn setup: \(exc)") }

        let snapResult = snapFn.call(withArguments: [
            JSValue(object: snapCallback, in: ctx)!,
            snapArgs
        ])
        if let exc = ctx.exception { throw BotGuardError.jsFailed("asyncSnapshotFn call: \(exc)") }
        let snapIsPromise = snapResult?.objectForKeyedSubscript("then")?.isObject == true
        pumpMicrotasks(ctx, count: 5)

        if snapIsPromise {
            pumpMicrotasks(ctx, count: 200)
        } else {
            pumpMicrotasks(ctx, count: 60)
        }

        guard let bgResponse = botguardResponse, !bgResponse.isEmpty else {
            throw BotGuardError.jsFailed("botguard response empty after asyncSnapshotFn")
        }
        bgLog.notice("[BotGuard] Phase 3 ✅ botguardResponse len=\(bgResponse.count)")

        // --- Phase 4: fetch integrity token (blocking URLSession, safe on jsQueue) ---
        // Returns (integrityToken: json[0], websafeFallback: json[3]).
        // json[0] is the token passed to getMinter; json[3] is used directly when getMinter is unavailable.
        let (integrityToken, websafeFallback, ttl) = try fetchIntegrityTokenSync(bgResponse: bgResponse)
        lastRunIntegrityTokenLen = integrityToken?.count ?? 0
        bgLog.notice("[BotGuard] Phase 4 ✅ integrityToken=\(integrityToken?.count ?? 0) websafeFallback=\(websafeFallback?.count ?? 0)")


        // --- Phase 5: mint PO token ---
        let token = try mintSync(
            ctx: ctx,
            signalOutput: webPoSignalOutput,
            integrityToken: integrityToken,
            websafeFallback: websafeFallback,
            videoId: videoId
        )
        return (token, ttl)
    }

    // MARK: - Phase 4: integrity token (blocking, on jsQueue)

    // Holds the dataTask callback result across a DispatchSemaphore hand-off.
    // @unchecked Sendable is safe here: jsQueue blocks on the semaphore while the
    // URLSession delegate queue writes, so there is no concurrent access in practice.
    private final class _ResultBox<T>: @unchecked Sendable {
        var value: T
        init(_ value: T) { self.value = value }
    }

    private func fetchIntegrityTokenSync(bgResponse: String) throws -> (integrityToken: String?, websafeFallback: String?, ttl: Int) {
        let payload = [Self.requestKey, bgResponse]
        var req = URLRequest(url: Self.waaGenerateITURL, timeoutInterval: 12)
        req.httpMethod = "POST"
        req.setValue("application/json+protobuf", forHTTPHeaderField: "Content-Type")
        req.setValue(Self.waaAPIKey,              forHTTPHeaderField: "x-goog-api-key")
        req.setValue("grpc-web-javascript/0.1",   forHTTPHeaderField: "x-user-agent")
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        let box = _ResultBox<Result<(integrityToken: String?, websafeFallback: String?, ttl: Int), Error>?>(nil)
        let sema = DispatchSemaphore(value: 0)
        let log = bgLog   // capture logger value to avoid 'self' capture in closure

        session.dataTask(with: req) { data, response, error in
            defer { sema.signal() }
            if let error { box.value = .failure(error); return }
            // GenerateIT response: [integrityToken, ttlSecs, mintRefreshThreshold, websafeFallbackToken]
            // json[0]: integrityTokenBasedRequestKey — input to getMinter() for full minting flow (may be nil)
            // json[3]: websafeFallbackToken — ready-to-use PO token when getMinter is not available (may be absent)
            // Guard requires non-empty JSON array; json[3] is accessed only when present (API format may vary).
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
                  !json.isEmpty else {
                let httpStatus = (response as? HTTPURLResponse)?.statusCode ?? -1
                let bodySnippet = data.flatMap { String(data: $0.prefix(200), encoding: .utf8) } ?? "<nil>"
                log.notice("[BotGuard] GenerateIT failed: HTTP \(httpStatus) body=\(bodySnippet)")
                box.value = .failure(BotGuardError.integrityTokenFailed(
                    "HTTP \(httpStatus) body=\(bodySnippet.prefix(80))"
                ))
                return
            }
            let integrityToken  = json[0] as? String          // may be nil (WAA returns null for JSC environment)
            let ttlSeconds      = json.count > 1 ? (json[1] as? Int ?? 3600) : 3600
            let websafeFallback = json.count > 3 ? json[3] as? String : nil  // ready-to-use PO token fallback
            log.notice("[BotGuard] GenerateIT: integrityToken=\(integrityToken?.count ?? 0) websafeFallback=\(websafeFallback?.count ?? 0)")
            guard integrityToken != nil || websafeFallback != nil else {
                box.value = .failure(BotGuardError.integrityTokenFailed("both integrityToken and websafeFallback are nil"))
                return
            }
            box.value = .success((integrityToken, websafeFallback, ttlSeconds))
        }.resume()

        sema.wait()
        return try box.value!.get()
    }

    // MARK: - Phase 5: mint (JS, on jsQueue)

    private func mintSync(
        ctx: JSContext,
        signalOutput: JSValue,
        integrityToken: String?,
        websafeFallback: String?,
        videoId: String
    ) throws -> String {

        // getMinter = webPoSignalOutput[0] (set by the VM during asyncSnapshotFn, when available)
        let getMinterFn = signalOutput.objectAtIndexedSubscript(0)
        let hasMinter = getMinterFn != nil && !getMinterFn!.isNull && !getMinterFn!.isUndefined
        lastRunHasMinter = hasMinter

        if !hasMinter {
            // webPoSignalOutput[0] not available — use websafeFallbackToken directly.
            // This token from GenerateIT (json[3]) is a ready-to-use URL-safe base64 PO token.
            guard let fallback = websafeFallback, !fallback.isEmpty else {
                throw BotGuardError.mintFailed("getMinter not set and no websafeFallbackToken available")
            }
            bgLog.notice("[BotGuard] ✅ using websafe fallback token (len=\(fallback.count)) for \(videoId)")
            return fallback
        }

        // Full minting flow: getMinter(integrityTokenBytes) → mintCallback(videoIdBytes) → PO token
        guard let integrityB64 = integrityToken, !integrityB64.isEmpty else {
            throw BotGuardError.mintFailed("getMinter available but integrityToken (json[0]) is nil")
        }

        // Decode integrity token bytes.
        // The token uses URL-safe base64 (- and _); convert to standard base64 before decoding.
        let standardB64 = integrityB64
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let rem = standardB64.count % 4
        let paddedB64 = rem == 0 ? standardB64 : standardB64 + String(repeating: "=", count: 4 - rem)
        guard let integrityData = Data(base64Encoded: paddedB64) else {
            throw BotGuardError.mintFailed("integrityToken base64 decode failed")
        }

        // Build JS Uint8Array for integrity token bytes
        let integrityU8 = try buildUint8Array(from: integrityData, in: ctx, label: "integrityToken")

        // mintCallback = await getMinter(integrityTokenBytes)  – may return Promise or function directly
        let getMinterResult = getMinterFn!.call(withArguments: [integrityU8])
        if let exc = ctx.exception { throw BotGuardError.mintFailed("getMinter(): \(exc)") }
        let mintCallbackFn = try resolvePromise(getMinterResult ?? JSValue(undefinedIn: ctx)!, in: ctx, label: "getMinter")

        guard !mintCallbackFn.isNull, !mintCallbackFn.isUndefined else {
            throw BotGuardError.mintFailed("mintCallback is null after getMinter")
        }

        // tokenBytes = await mintCallback(TextEncoder().encode(videoId))
        guard let videoIdData = videoId.data(using: .utf8) else {
            throw BotGuardError.mintFailed("videoId UTF-8 encoding failed")
        }
        let videoIdU8 = try buildUint8Array(from: videoIdData, in: ctx, label: "videoId")

        let mintResult = mintCallbackFn.call(withArguments: [videoIdU8])
        if let exc = ctx.exception { throw BotGuardError.mintFailed("mintCallback(): \(exc)") }
        let tokenValue = try resolvePromise(mintResult ?? JSValue(undefinedIn: ctx)!, in: ctx, label: "mintCallback")

        // Extract bytes from the result (Uint8Array or plain Array)
        var tokenBytes = Data()
        if let lengthVal = tokenValue.objectForKeyedSubscript("length"), lengthVal.isNumber {
            let length = Int(lengthVal.toInt32())
            for i in 0..<length {
                let byte = tokenValue.objectAtIndexedSubscript(i).toUInt32()
                tokenBytes.append(UInt8(byte & 0xFF))
            }
        }

        guard !tokenBytes.isEmpty else {
            throw BotGuardError.mintFailed("mint result was empty")
        }

        return tokenBytes.base64EncodedString()
    }

    // MARK: - JSContext helpers

    /// Installs minimal polyfills for APIs the BotGuard interpreter JS may reference.
    private func installPolyfills(_ ctx: JSContext) {
        // window / globalThis aliasing (BotGuard may write to window.X)
        ctx.evaluateScript("""
        if (typeof window === 'undefined') { var window = this; }
        if (typeof globalThis === 'undefined') { var globalThis = window; }
        if (typeof self === 'undefined') { var self = window; }
        """)

        // __bgLog — native Swift bridge set directly on JSContext; survives BotGuard's console override.
        // Used by our diagnostic JS (window Proxy) and re-attached to console.log after VM loads.
        let bgLogCapture = bgLog
        let consoleFn: @convention(block) (JSValue) -> Void = { val in
            let text = val.toString() ?? ""
            bgLogCapture.warning("[BotGuard-JS] \(text, privacy: .public)")
        }
        ctx.setObject(consoleFn, forKeyedSubscript: "__bgLog" as NSString)
        if let con = ctx.evaluateScript("({})") {
            con.setObject(consoleFn, forKeyedSubscript: "log" as NSString)
            con.setObject(consoleFn, forKeyedSubscript: "warn" as NSString)
            con.setObject(consoleFn, forKeyedSubscript: "error" as NSString)
            ctx.setObject(con, forKeyedSubscript: "console" as NSString)
        }

        // performance — timing fingerprinting + Chrome-specific memory API
        // JSC does not expose the Web Performance API; provide a polyfill.
        // performance.memory is Chrome-only; stub with plausible heap values to prevent
        // "TypeError: undefined is not an object" when code does performance.memory.usedJSHeapSize.
        ctx.evaluateScript("""
        if (typeof performance === 'undefined') {
            var performance = (function() {
                var _origin = Date.now();
                return {
                    timeOrigin: _origin,
                    now: function() { return Date.now() - _origin; },
                    memory: { usedJSHeapSize: 8000000, totalJSHeapSize: 20000000, jsHeapSizeLimit: 2172649472 },
                    timing: { navigationStart: Date.now(), loadEventEnd: Date.now() },
                    getEntriesByType: function() { return []; },
                    getEntriesByName: function() { return []; },
                    mark: function(){}, measure: function(){}, clearMarks: function(){}, clearMeasures: function(){}
                };
            })();
            window.performance = performance;
        }
        """)

        // TextEncoder / TextDecoder — required by BotGuard minting JS (encodes videoId bytes).
        // Provide a UTF-8 subset sufficient for ASCII videoIds.
        ctx.evaluateScript("""
        if (typeof TextEncoder === 'undefined') {
            var TextEncoder = function() {};
            TextEncoder.prototype.encode = function(str) {
                var bytes = [];
                for (var i = 0; i < str.length; i++) {
                    var c = str.charCodeAt(i);
                    if (c < 0x80) { bytes.push(c); }
                    else if (c < 0x800) { bytes.push(0xC0 | (c >> 6), 0x80 | (c & 0x3F)); }
                    else { bytes.push(0xE0 | (c >> 12), 0x80 | ((c >> 6) & 0x3F), 0x80 | (c & 0x3F)); }
                }
                var arr = new Uint8Array(bytes.length);
                for (var j = 0; j < bytes.length; j++) arr[j] = bytes[j];
                return arr;
            };
        }
        if (typeof TextDecoder === 'undefined') {
            var TextDecoder = function() {};
            TextDecoder.prototype.decode = function(arr) {
                var str = '';
                for (var i = 0; i < arr.length; i++) { str += String.fromCharCode(arr[i]); }
                return str;
            };
        }
        """)

        // btoa / atob — base64 helpers used in some BotGuard variants.
        ctx.evaluateScript("""
        if (typeof btoa === 'undefined') {
            var _b64chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
            var btoa = function(s) {
                var o = '', i = 0, b;
                while (i < s.length) {
                    b = (s.charCodeAt(i++) & 0xFF) << 16 | (s.charCodeAt(i++) & 0xFF) << 8 | (s.charCodeAt(i++) & 0xFF);
                    o += _b64chars[b >> 18 & 0x3F] + _b64chars[b >> 12 & 0x3F] + _b64chars[b >> 6 & 0x3F] + _b64chars[b & 0x3F];
                }
                return (s.length % 3 === 2 ? o.slice(0,-1)+'=' : s.length % 3 === 1 ? o.slice(0,-2)+'==' : o);
            };
            var atob = function(s) {
                s = s.replace(/[^A-Za-z0-9+/]/g,'');
                var o = '', i = 0, b;
                while (i < s.length) {
                    b = (_b64chars.indexOf(s[i++])<<18)|(_b64chars.indexOf(s[i++])<<12)|(_b64chars.indexOf(s[i++])<<6)|_b64chars.indexOf(s[i++]);
                    o += String.fromCharCode((b>>16)&0xFF,(b>>8)&0xFF,b&0xFF);
                }
                return o;
            };
        }
        """)

        // location stub — prevents "undefined is not an object" when BotGuard reads location.href
        ctx.evaluateScript("""
        if (typeof location === 'undefined') {
            var location = { href: 'https://www.youtube.com/', hostname: 'www.youtube.com',
                             origin: 'https://www.youtube.com', protocol: 'https:',
                             pathname: '/', search: '', hash: '' };
        }
        """)

        // screen — used for display fingerprinting (e.g. screen.width, screen.colorDepth)
        ctx.evaluateScript("""
        if (typeof screen === 'undefined') {
            var screen = { width: 393, height: 852, availWidth: 393, availHeight: 852,
                           colorDepth: 24, pixelDepth: 24 };
            window.screen = screen;
        }
        """)

        // devicePixelRatio / innerWidth / innerHeight — read by some BotGuard fingerprinting paths
        ctx.evaluateScript("""
        if (typeof devicePixelRatio === 'undefined') { var devicePixelRatio = 3; window.devicePixelRatio = 3; }
        if (typeof innerWidth === 'undefined')        { var innerWidth = 393;  window.innerWidth = 393; }
        if (typeof innerHeight === 'undefined')       { var innerHeight = 852; window.innerHeight = 852; }
        """)

        // history — prevents crash on history.length or history.pushState
        ctx.evaluateScript("""
        if (typeof history === 'undefined') {
            var history = { length: 1,
                            back: function(){}, forward: function(){}, go: function(){},
                            pushState: function(){}, replaceState: function(){} };
            window.history = history;
        }
        """)

        // localStorage / sessionStorage — no-op stubs
        ctx.evaluateScript("""
        if (typeof localStorage === 'undefined') {
            var _store = {};
            var localStorage = { getItem: function(k){ return _store[k]||null; },
                                 setItem: function(k,v){ _store[k]=String(v); },
                                 removeItem: function(k){ delete _store[k]; },
                                 clear: function(){ _store={}; }, length: 0 };
            window.localStorage = localStorage;
        }
        if (typeof sessionStorage === 'undefined') {
            var _ss = {};
            var sessionStorage = { getItem: function(k){ return _ss[k]||null; },
                                   setItem: function(k,v){ _ss[k]=String(v); },
                                   removeItem: function(k){ delete _ss[k]; },
                                   clear: function(){ _ss={}; }, length: 0 };
            window.sessionStorage = sessionStorage;
        }
        """)

        // Native CryptoKit bridges for crypto.subtle — HMAC-SHA256 and SHA-256.
        // Set as JSC globals; survives any JS-level override of window.crypto.
        let hmacFn: @convention(block) (JSValue, JSValue) -> JSValue = { keyArr, dataArr in
            let nCtx = JSContext.current()!
            var key = Data(), msg = Data()
            let kl = Int(keyArr.objectForKeyedSubscript("length")?.toInt32() ?? 0)
            for i in 0..<kl { key.append(UInt8(keyArr.objectAtIndexedSubscript(i).toUInt32() & 0xFF)) }
            let dl = Int(dataArr.objectForKeyedSubscript("length")?.toInt32() ?? 0)
            for i in 0..<dl { msg.append(UInt8(dataArr.objectAtIndexedSubscript(i).toUInt32() & 0xFF)) }
            bgLogCapture.info("[BotGuard] __bgCrypto_hmac keyLen=\(kl, privacy: .public) dataLen=\(dl, privacy: .public)")
            let symmetricKey = SymmetricKey(data: key.isEmpty ? Data(repeating: 0, count: 32) : key)
            let mac = Array(HMAC<SHA256>.authenticationCode(for: msg, using: symmetricKey))
            let arr = nCtx.evaluateScript("new Uint8Array(\(mac.count))")!
            for (i, b) in mac.enumerated() { arr.setObject(NSNumber(value: b), atIndexedSubscript: i) }
            return arr
        }
        ctx.setObject(hmacFn, forKeyedSubscript: "__bgCrypto_hmac" as NSString)

        let sha256Fn: @convention(block) (JSValue) -> JSValue = { dataArr in
            let nCtx = JSContext.current()!
            var msg = Data()
            let dl = Int(dataArr.objectForKeyedSubscript("length")?.toInt32() ?? 0)
            for i in 0..<dl { msg.append(UInt8(dataArr.objectAtIndexedSubscript(i).toUInt32() & 0xFF)) }
            let digest = Array(SHA256.hash(data: msg))
            let arr = nCtx.evaluateScript("new Uint8Array(\(digest.count))")!
            for (i, b) in digest.enumerated() { arr.setObject(NSNumber(value: b), atIndexedSubscript: i) }
            return arr
        }
        ctx.setObject(sha256Fn, forKeyedSubscript: "__bgCrypto_sha256" as NSString)

        // crypto.getRandomValues — BotGuard may use it for nonce generation.
        let getRandomValuesFn: @convention(block) (JSValue) -> JSValue = { arr in
            let len = Int(arr.objectForKeyedSubscript("length")?.toInt32() ?? 0)
            for i in 0..<len {
                arr.setObject(NSNumber(value: Int.random(in: 0...255)), atIndexedSubscript: i)
            }
            return arr
        }
        ctx.evaluateScript("if (typeof crypto === 'undefined') { var crypto = {}; }")
        let cryptoObj = ctx.globalObject.objectForKeyedSubscript("crypto")
        cryptoObj?.setObject(getRandomValuesFn, forKeyedSubscript: "getRandomValues" as NSString)

        // crypto.subtle polyfill — backed by __bgCrypto_hmac (HMAC-SHA256) and __bgCrypto_sha256.
        // BotGuard uses crypto.subtle.importKey + crypto.subtle.sign to create the getMinter factory
        // (webPoSignalOutput[0]). Without this, importKey throws TypeError in a microtask.
        ctx.evaluateScript("""
        (function() {
            function _toU8(v) {
                if (v instanceof Uint8Array) return v;
                if (v && v.buffer instanceof ArrayBuffer) return new Uint8Array(v.buffer);
                if (v instanceof ArrayBuffer) return new Uint8Array(v);
                return new Uint8Array(v || 0);
            }
            var subtle = {
                importKey: function(format, keyData, algorithm, extractable, usages) {
                    __bgLog('[crypto] importKey fmt=' + format + ' algo=' + (algorithm && algorithm.name));
                    try {
                        var raw = _toU8(keyData);
                        return Promise.resolve({ type:'secret', algorithm:algorithm,
                            extractable:!!extractable, usages:usages||[], _raw:raw });
                    } catch(e) { __bgLog('[crypto] importKey ERR ' + e); return Promise.reject(e); }
                },
                sign: function(algorithm, key, data) {
                    __bgLog('[crypto] sign algo=' + (algorithm && algorithm.name) + ' keyLen=' + (key && key._raw && key._raw.length));
                    try {
                        var u8 = _toU8(data);
                        var r = __bgCrypto_hmac(key._raw, u8);
                        return r ? Promise.resolve(r.buffer) : Promise.reject(new Error('HMAC failed'));
                    } catch(e) { __bgLog('[crypto] sign ERR ' + e); return Promise.reject(e); }
                },
                verify: function(algorithm, key, signature, data) {
                    try {
                        var u8 = _toU8(data), sig = _toU8(signature);
                        var r = __bgCrypto_hmac(key._raw, u8);
                        if (!r || r.length !== sig.length) return Promise.resolve(false);
                        for (var i = 0; i < r.length; i++) { if (r[i] !== sig[i]) return Promise.resolve(false); }
                        return Promise.resolve(true);
                    } catch(e) { return Promise.reject(e); }
                },
                digest: function(algorithm, data) {
                    try {
                        var u8 = _toU8(data);
                        var r = __bgCrypto_sha256(u8);
                        return r ? Promise.resolve(r.buffer) : Promise.reject(new Error('SHA256 failed'));
                    } catch(e) { return Promise.reject(e); }
                },
                generateKey: function(algorithm, extractable, usages) {
                    var len = ((algorithm && algorithm.length) || 256) / 8;
                    var bytes = new Uint8Array(len);
                    crypto.getRandomValues(bytes);
                    return Promise.resolve({ type:'secret', algorithm:algorithm,
                        extractable:!!extractable, usages:usages||[], _raw:bytes });
                },
                exportKey: function(format, key) {
                    return format === 'raw' ? Promise.resolve(key._raw.buffer)
                                           : Promise.reject(new Error('exportKey: ' + format));
                },
                deriveKey:  function() { return Promise.reject(new Error('deriveKey not supported')); },
                deriveBits: function() { return Promise.reject(new Error('deriveBits not supported')); },
                encrypt:    function() { return Promise.reject(new Error('encrypt not supported')); },
                decrypt:    function() { return Promise.reject(new Error('decrypt not supported')); },
                wrapKey:    function() { return Promise.reject(new Error('wrapKey not supported')); },
                unwrapKey:  function() { return Promise.reject(new Error('unwrapKey not supported')); }
            };
            window.crypto.subtle = subtle;
            // Save as global so we can re-install after VM loading overwrites window.crypto.
            __bgSubtle = subtle;
        })();
        """)

        // document stub — createElement('canvas') returns a canvas with a 2D context stub
        // so BotGuard canvas-fingerprinting code does not throw "undefined is not an object".
        ctx.evaluateScript("""
        if (typeof document === 'undefined') {
            var _canvas2dCtx = {
                canvas: null,
                fillRect: function(){}, clearRect: function(){}, strokeRect: function(){},
                getImageData: function(){ return { data: new Uint8ClampedArray(4), width:1, height:1 }; },
                putImageData: function(){}, drawImage: function(){},
                fillText: function(){}, strokeText: function(){},
                measureText: function(){ return { width:8, actualBoundingBoxAscent:10, actualBoundingBoxDescent:2 }; },
                beginPath: function(){}, closePath: function(){},
                moveTo: function(){}, lineTo: function(){}, arc: function(){}, rect: function(){},
                stroke: function(){}, fill: function(){},
                save: function(){}, restore: function(){},
                translate: function(){}, scale: function(){}, rotate: function(){},
                transform: function(){}, setTransform: function(){},
                createLinearGradient: function(){ return { addColorStop: function(){} }; },
                createRadialGradient: function(){ return { addColorStop: function(){} }; },
                createPattern: function(){ return null; },
                isPointInPath: function(){ return false; },
                fillStyle: '#000', strokeStyle: '#000', font: '10px sans-serif',
                textAlign: 'start', textBaseline: 'alphabetic',
                lineWidth: 1, lineCap: 'butt', lineJoin: 'miter', miterLimit: 10,
                shadowBlur: 0, shadowColor: 'rgba(0,0,0,0)', shadowOffsetX: 0, shadowOffsetY: 0,
                globalAlpha: 1, globalCompositeOperation: 'source-over'
            };
            function _makeCanvas() {
                var c = {
                    tagName: 'CANVAS', width: 300, height: 150, style: {},
                    setAttribute: function(k,v){ this[k]=v; }, appendChild: function(){},
                    addEventListener: function(){}, removeEventListener: function(){},
                    getContext: function(type) {
                        if (type === '2d') { _canvas2dCtx.canvas = this; return _canvas2dCtx; }
                        return null;  // WebGL not supported in JSC; null avoids crash
                    },
                    toDataURL: function(){ return 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=='; },
                    toBlob: function(cb){ cb && cb(null); }
                };
                return c;
            }
            var document = {
                createElement: function(tag) {
                    if (tag === 'canvas' || tag === 'CANVAS') return _makeCanvas();
                    return { tagName: tag, style: {}, setAttribute: function(){}, appendChild: function(){},
                             addEventListener: function(){}, removeEventListener: function(){} };
                },
                createTextNode: function(t) { return { textContent: t }; },
                getElementsByTagName: function() { return []; },
                getElementById: function() { return null; },
                querySelector: function() { return null; },
                querySelectorAll: function() { return []; },
                head: { appendChild: function(){}, querySelector: function(){ return null; } },
                body: { appendChild: function(){}, querySelector: function(){ return null; } },
                documentElement: { style: {}, getAttribute: function(){ return null; } },
                cookie: '',
                hidden: false,
                visibilityState: 'visible',
                addEventListener: function(){},
                removeEventListener: function(){}
            };
            window.document = document;
        }
        """)

        // navigator — extended with hardware/platform fingerprinting properties BotGuard reads
        ctx.evaluateScript("""
        if (typeof navigator === 'undefined') {
            var navigator = {
                userAgent: 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148',
                appName: 'Netscape', appVersion: '5.0',
                platform: 'iPhone', vendor: 'Apple Computer, Inc.',
                language: 'en-US', languages: ['en-US', 'en'],
                cookieEnabled: true, onLine: true,
                hardwareConcurrency: 6,
                maxTouchPoints: 5,
                doNotTrack: null,
                plugins: { length: 0, item: function(){ return null; }, namedItem: function(){ return null; } },
                mimeTypes: { length: 0, item: function(){ return null; }, namedItem: function(){ return null; } },
                sendBeacon: function(){ return false; },
                vibrate: function(){ return false; },
                getBattery: function(){ return Promise.resolve({ charging: true, chargingTime: 0, dischargingTime: Infinity, level: 1 }); },
                connection: { effectiveType: '4g', downlink: 10, rtt: 50, saveData: false },
                mediaDevices: { enumerateDevices: function(){ return Promise.resolve([]); } },
                permissions: { query: function(){ return Promise.resolve({ state: 'denied' }); } }
            };
            window.navigator = navigator;
        }
        navigator.webdriver = false;
        navigator.deviceMemory = navigator.deviceMemory || 4;
        if (!navigator.storage) {
            navigator.storage = {
                estimate: function() { return Promise.resolve({ usage: 123456, quota: 438190080 }); },
                persisted: function() { return Promise.resolve(false); }
            };
        }
        """)

        // requestAnimationFrame / cancelAnimationFrame — timing fingerprinting
        ctx.evaluateScript("""
        if (typeof requestAnimationFrame === 'undefined') {
            var requestAnimationFrame = function(cb) { if (typeof cb === 'function') cb(performance.now()); return 0; };
            var cancelAnimationFrame = function() {};
            window.requestAnimationFrame = requestAnimationFrame;
            window.cancelAnimationFrame = cancelAnimationFrame;
        }
        """)

        // AudioContext / webkitAudioContext — audio-fingerprinting stub.
        // BotGuard may probe these; provide no-op constructors so "new AudioContext()" doesn't throw.
        ctx.evaluateScript("""
        if (typeof AudioContext === 'undefined') {
            var _AudioCtxProto = {
                createOscillator: function(){ return { type:'', frequency:{ value:0, setValueAtTime:function(){} }, connect:function(){}, start:function(){}, stop:function(){} }; },
                createDynamicsCompressor: function(){ return { threshold:{value:0}, knee:{value:0}, ratio:{value:0}, attack:{value:0}, release:{value:0}, connect:function(){} }; },
                createBuffer: function(){ return {}; },
                createBufferSource: function(){ return { buffer:null, connect:function(){}, start:function(){}, stop:function(){} }; },
                createAnalyser: function(){ return { fftSize:2048, getFloatFrequencyData:function(){}, getByteFrequencyData:function(){} }; },
                createGain: function(){ return { gain:{value:1}, connect:function(){} }; },
                destination: {}, sampleRate: 44100, state: 'running',
                close: function(){ return Promise.resolve(); },
                resume: function(){ return Promise.resolve(); },
                suspend: function(){ return Promise.resolve(); }
            };
            var AudioContext = function() { return Object.create(_AudioCtxProto); };
            var webkitAudioContext = AudioContext;
            var OfflineAudioContext = function(channels, length, sampleRate) {
                var ctx = Object.create(_AudioCtxProto);
                ctx.startRendering = function(){ return Promise.resolve({}); };
                return ctx;
            };
            window.AudioContext = AudioContext;
            window.webkitAudioContext = webkitAudioContext;
            window.OfflineAudioContext = OfflineAudioContext;
            window.webkitOfflineAudioContext = OfflineAudioContext;
        }
        """)

        // setTimeout / setInterval stubs (synchronous — fires callback immediately for best-effort compat)
        // BotGuard typically does not rely on real timer semantics in its VM.
        let setTimeoutFn: @convention(block) (JSValue, JSValue) -> NSNumber = { cb, _ in
            if cb.isObject { cb.call(withArguments: []) }
            return 0
        }
        ctx.setObject(setTimeoutFn, forKeyedSubscript: "setTimeout" as NSString)
        ctx.setObject({ (_: JSValue, _: JSValue) -> NSNumber in 0 } as @convention(block) (JSValue, JSValue) -> NSNumber,
                      forKeyedSubscript: "setInterval" as NSString)
        ctx.setObject({ (_: NSNumber) in } as @convention(block) (NSNumber) -> Void,
                      forKeyedSubscript: "clearTimeout" as NSString)
        ctx.setObject({ (_: NSNumber) in } as @convention(block) (NSNumber) -> Void,
                      forKeyedSubscript: "clearInterval" as NSString)

        // queueMicrotask — async scheduling; some BotGuard variants use it
        ctx.evaluateScript("""
        if (typeof queueMicrotask === 'undefined') {
            var queueMicrotask = function(fn) { Promise.resolve().then(fn); };
            window.queueMicrotask = queueMicrotask;
        }
        """)

        // WebAssembly stub — BotGuard checks typeof WebAssembly for capability fingerprinting
        ctx.evaluateScript("""
        if (typeof WebAssembly === 'undefined') {
            var WebAssembly = {
                compile: function() { return Promise.reject(new Error('WASM not available')); },
                instantiate: function() { return Promise.reject(new Error('WASM not available')); },
                validate: function() { return false; },
                compileStreaming: function() { return Promise.reject(new Error('WASM not available')); },
                instantiateStreaming: function() { return Promise.reject(new Error('WASM not available')); }
            };
            window.WebAssembly = WebAssembly;
        }
        """)

        // Window self-reference properties — iframe / popup / security context detection
        ctx.evaluateScript("""
        window.parent = window;
        window.top = window;
        window.opener = null;
        window.closed = false;
        window.name = window.name || '';
        window.frameElement = null;
        window.isSecureContext = true;
        window.crossOriginIsolated = false;
        window.origin = window.origin || 'https://www.youtube.com';
        """)

        // matchMedia — media query API (color scheme, display fingerprinting)
        ctx.evaluateScript("""
        if (typeof matchMedia === 'undefined') {
            var matchMedia = function(q) {
                return { matches: false, media: q || '', onchange: null,
                         addListener: function(){}, removeListener: function(){},
                         addEventListener: function(){}, removeEventListener: function(){},
                         dispatchEvent: function(){ return false; } };
            };
            window.matchMedia = matchMedia;
        }
        if (typeof getComputedStyle === 'undefined') {
            var getComputedStyle = function() {
                return { getPropertyValue: function(){ return ''; }, setProperty: function(){}, length: 0 };
            };
            window.getComputedStyle = getComputedStyle;
        }
        """)

        // Diagnostic: Proxy on window to identify which property is accessed as undefined.
        // Each access to window.X where X is undefined gets logged via console.log.
        // This lets us pinpoint the missing polyfill without needing a JS stack trace.
        ctx.evaluateScript("""
        (function() {
            try {
                if (typeof Proxy === 'undefined' || typeof Reflect === 'undefined') return;
                var _skip = { undefined:1, NaN:1, Infinity:1, arguments:1, eval:1 };
                var _realWin = window;
                var _proxyWin = new Proxy(_realWin, {
                    get: function(target, prop) {
                        var v = Reflect.get(target, prop);
                        if (v === undefined && typeof prop === 'string' && !_skip[prop] && prop.indexOf('@@') === -1) {
                            __bgLog('[win-miss] window.' + prop);
                        }
                        return v;
                    }
                });
                // Shadow the var 'window' in this scope — code using window.X will hit the proxy
                window = _proxyWin;
                globalThis = _proxyWin;
                self = _proxyWin;
            } catch(e) { __bgLog('[win-proxy-err] ' + e); }
        })();
        """)
    }

    /// Builds a JS `Uint8Array` from `Data`. Used for passing byte arrays across the Swift/JS bridge.
    private func buildUint8Array(from data: Data, in ctx: JSContext, label: String) throws -> JSValue {
        guard let arr = ctx.evaluateScript("new Uint8Array(\(data.count))"),
              !arr.isNull, !arr.isUndefined else {
            throw BotGuardError.mintFailed("Uint8Array(\(label)) creation failed")
        }
        for (i, byte) in data.enumerated() {
            arr.setObject(NSNumber(value: byte), atIndexedSubscript: i)
        }
        return arr
    }

    /// Pumps pending JSC microtasks by re-entering the JS engine.
    /// Each call to `evaluateScript` creates a drain-point where JSC flushes its microtask queue.
    private func pumpMicrotasks(_ ctx: JSContext, count: Int) {
        for _ in 0..<count { ctx.evaluateScript("undefined") }
    }

    /// Resolves a JS Promise synchronously using a pure-JS then-handler that writes
    /// the settled value to a context global (`__bgR`), then reads it back in Swift.
    ///
    /// Avoids crossing the JS→Swift callback boundary during microtask draining
    /// (Swift `@convention(block)` callbacks from within JSC microtasks can be unreliable
    /// when microtask draining occurs re-entrantly inside `JSObjectCallAsFunction`).
    ///
    /// The `__bgR` global is single-use and deleted after reading; safe because jsQueue is serial.
    /// Returns `promise` directly if it is not thenable (mirrors `await nonPromise` in JS).
    private func resolvePromise(_ promise: JSValue, in ctx: JSContext, label: String, maxPumps: Int = 50) throws -> JSValue {
        guard promise.objectForKeyedSubscript("then")?.isObject == true else {
            return promise
        }

        // Store the promise in a JS global so the IIFE can access it by name.
        ctx.setObject(promise, forKeyedSubscript: "__bgP" as NSString)

        // The IIFE calls p.then(handler) as a method (this=p, correct binding).
        // JSEvaluateScript calls vm.drainMicrotasks() after the IIFE returns, which
        // executes the queued then-callback and sets __bgR before returning to Swift.
        ctx.evaluateScript("""
        (function() {
            var p = globalThis.__bgP;
            delete globalThis.__bgP;
            p.then(
                function(v) { globalThis.__bgR = { ok: 1, v: v }; },
                function(e) { globalThis.__bgR = { ok: 0, e: String(e) }; }
            );
        })();
        """)
        if let exc = ctx.exception {
            throw BotGuardError.jsFailed("resolvePromise '\(label)' setup: \(exc)")
        }

        // Read result — usually set during the evaluateScript above; pump more if needed
        // (e.g. multi-hop Promise chains that require additional microtask turns).
        for _ in 0..<maxPumps {
            if let r = ctx.evaluateScript("globalThis.__bgR"),
               !r.isNull, !r.isUndefined {
                ctx.evaluateScript("delete globalThis.__bgR")
                if r.objectForKeyedSubscript("ok")?.toInt32() == 1 {
                    return r.objectForKeyedSubscript("v") ?? JSValue(undefinedIn: ctx)!
                } else {
                    let err = r.objectForKeyedSubscript("e")?.toString() ?? "rejected"
                    throw BotGuardError.jsFailed("Promise '\(label)' rejected: \(err)")
                }
            }
            ctx.evaluateScript("undefined")   // additional microtask drain
        }

        throw BotGuardError.jsFailed("Promise '\(label)' did not settle after \(maxPumps) pumps")
    }
}
