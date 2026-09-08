#if canImport(WebKit)
import WebKit
import os
import iPocketTubeCore

private let bgwvLog = Logger(subsystem: appSubsystem, category: "BotGuardWV")

// MARK: - BotGuardWebViewRunner

/// Runs the BotGuard WAA pipeline inside a hidden WKWebView (real WebKit engine).
///
/// **Why WKWebView instead of JSC:**
/// JavaScriptCore (used by `BotGuardClient`) cannot satisfy the WAA server's browser
/// attestation check: WAA's GenerateIT returns `json[0] = null` (no integrityToken) for
/// JSC-produced snapshots, forcing the websafe fallback path (`json[3]`). That fallback
/// token is accepted by the YouTube InnerTube API but **rejected by the CDN** for
/// `rqh=1` adaptive streams (HTTP 403, CFHTTP err=-12660).
///
/// WKWebView provides:
/// - Real `crypto.subtle` → BotGuard fingerprint is browser-quality
/// - Real `fetch()` → WAA network calls work with proper browser headers
/// - Proper event loop → async/await and Promises resolve correctly
/// - youtube.com origin (via robots.txt base page) → CORS to jnn-pa.googleapis.com
///
/// When the pipeline succeeds with `hasMinter=true`, the CDN-accepted minted token is
/// returned. When it fails (WAA still returns null integrityToken in WKWebView, or any
/// error), falls back to the websafe fallback — same result as `BotGuardClient`.
///
/// **Lifecycle:**
/// - `prepare(for:)` runs once (or when the cached mintCallback expires); typically 3–8 s.
/// - `isReady` is true while the mintCallback is cached.
/// - `mintToken(for:)` calls the cached mintCallback (<5 ms); call `prepare(for:)` first.
@MainActor
public final class BotGuardWebViewRunner: NSObject {

    public static let shared = BotGuardWebViewRunner()

    // MARK: - WAA constants (same as BotGuardClient)
    private static let waaAPIKey  = "AIzaSyDyT5W0Jh49F30Pqqtyfdf7pDLFKLJoAnw"
    private static let requestKey = "O43z0dpjhgX20SCx4KAo"

    // MARK: - State
    private var webView: WKWebView?
    private var mintCallbackReady = false
    private var mintExpiry: Date?
    /// Ongoing or completed prepare task; multiple callers `await` the same task.
    private var prepareTask: Task<PrepareResult?, Never>?
    /// The video ID passed to the most recent `launchWebView(videoId:)` call.
    private var currentVideoId: String = ""
    /// The WEB session's visitorData extracted from the WKWebView's youtube.com context.
    /// Used as the canonical BotGuard identifier when minting tokens, ensuring consistency
    /// with the session that solved the BotGuard challenge.
    public private(set) var webVisitorData: String = ""

    /// Continuation for the active prepare task (set in launchWebView; resumed by WKScriptMessageHandler).
    private var prepareCont: CheckedContinuation<PrepareResult, Never>?
    /// Continuation for `mintToken(for:)`.
    private var mintCont: CheckedContinuation<String?, Never>?

    // MARK: - Public types

    public struct PrepareResult: Sendable {
        public let hasMinter: Bool
        public let websafeToken: String?
        public let ttl: Int
        public let integrityTokenLen: Int
        /// The WEB client's visitorData from the WKWebView's youtube.com session.
        /// Empty string when the guide call failed or was not attempted.
        public let webVisitorData: String
    }

    // MARK: - Public API

    /// True when the mintCallback is cached and within its TTL (~12 h).
    public var isReady: Bool {
        mintCallbackReady && (mintExpiry.map { Date() < $0 } ?? false)
    }

    /// Runs the full BotGuard WAA pipeline in WKWebView.
    ///
    /// Multiple concurrent callers `await` the same in-progress task — only one WKWebView
    /// is ever launched. Returns `nil` if already ready; returns the `PrepareResult` on first run.
    @discardableResult
    public func prepare(for videoId: String = "") async -> PrepareResult? {
        if isReady { return nil }

        // If preparation is already running, wait for the same task to complete.
        if let ongoing = prepareTask {
            bgwvLog.notice("[BotGuardWV] prepare() — joining in-progress task")
            _ = await ongoing.value
            return nil
        }

        bgwvLog.notice("[BotGuardWV] prepare() starting — will load youtube.com context for BotGuard pipeline")

        let task = Task<PrepareResult?, Never> { @MainActor [weak self] in
            guard let self else { return nil }
            let result = await withCheckedContinuation { (cont: CheckedContinuation<PrepareResult, Never>) in
                self.prepareCont = cont
                self.launchWebView(videoId: videoId)
            }
            if result.hasMinter {
                self.mintCallbackReady = true
                self.mintExpiry = Date().addingTimeInterval(TimeInterval(result.ttl > 0 ? result.ttl : 3600))
                bgwvLog.notice("[BotGuardWV] ✅ prepare() succeeded — hasMinter=true integrityTokenLen=\(result.integrityTokenLen) ttl=\(result.ttl)s")
                // Copy WKWebView's YouTube/Google cookies to HTTPCookieStorage.shared.
                // AVFoundation (AVURLAsset) uses the shared cookie storage when making
                // CDN requests, so propagating the WKWebView's youtube.com session cookies
                // ensures the CDN sees the same session that solved the BotGuard challenge.
                await self.propagateWebViewCookies()
            } else {
                bgwvLog.notice("[BotGuardWV] ⚠️ prepare() — hasMinter=false (WAA returned null integrityToken; websafe fallback path)")
            }
            self.prepareTask = nil
            return result
        }
        prepareTask = task
        return await task.value
    }

    /// Mints a PO token using the cached WKWebView `mintCallback`.
    ///
    /// The `identifier` should be the session's `visitorData` string from InnerTube API
    /// responses. The visitorData is base64url-decoded to raw proto bytes before being
    /// passed to `mintCallback`, matching yt-dlp's implementation and the YouTube web
    /// player's expected identifier format. Falls back to empty string when unavailable.
    ///
    /// Requires `prepare()` to have been called first. Returns `nil` if the mintCallback
    /// is not ready or if the JS call fails.
    public func mintToken(identifier: String) async -> String? {
        guard isReady, let wv = webView else {
            bgwvLog.notice("[BotGuardWV] mintToken — not ready (isReady=\(self.isReady), wv=\(self.webView != nil))")
            return nil
        }

        // Use the WEB session's visitorData as the canonical BotGuard identifier when
        // available — this is the value that the WKWebView's BotGuard challenge was solved
        // under, ensuring the CDN can validate the minted token against the correct session.
        // Fall back to the caller-supplied identifier when webVisitorData is not available.
        let effectiveIdentifier = webVisitorData.isEmpty ? identifier : webVisitorData
        // The identifier is embedded verbatim in the JS string — escape backslashes then single-quotes.
        let safeIdentifier = effectiveIdentifier
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        let js = """
        (function() {
            if (typeof window.__bgMintCallback !== 'function') {
                window.webkit.messageHandlers.botguardRunner.postMessage(
                    JSON.stringify({type:'mint',error:'no mintCallback'})
                );
                return;
            }
            var checkExpiry = window.__bgMintExpiry || 0;
            if (Date.now() > checkExpiry) {
                window.webkit.messageHandlers.botguardRunner.postMessage(
                    JSON.stringify({type:'mint',error:'mintCallback expired'})
                );
                return;
            }
            // Canonical BotGuard identifier: raw proto bytes of the visitorData.
            // visitorData is a base64url-encoded protobuf. The WAA minter expects the
            // decoded bytes (matching yt-dlp's: base64url_decode(visitor_data)).
            // We normalise base64url → base64 (+padding) before atob().
            var identifierBytes;
            try {
                var b64fix = '\(safeIdentifier)'.replace(/-/g, '+').replace(/_/g, '/');
                while (b64fix.length % 4 !== 0) { b64fix += '='; }
                var decoded = atob(b64fix);
                identifierBytes = Uint8Array.from(decoded, function(c) { return c.charCodeAt(0); });
            } catch(e) {
                // Fallback: pass UTF-8 bytes of the identifier string if base64 decode fails
                identifierBytes = new TextEncoder().encode('\(safeIdentifier)');
            }
            Promise.resolve(window.__bgMintCallback(identifierBytes)).then(function(mintedBytes) {
                var arr = (mintedBytes instanceof Uint8Array) ? mintedBytes : new Uint8Array(mintedBytes);
                // Encode as URL-safe base64 (no padding, + → -, / → _) — YouTube CDN format.
                var b64std = btoa(String.fromCharCode.apply(null, Array.from(arr)));
                var b64 = b64std.replace(/\\+/g, '-').replace(/\\//g, '_').replace(/=/g, '');
                window.webkit.messageHandlers.botguardRunner.postMessage(
                    JSON.stringify({type:'mint',token:b64})
                );
            }).catch(function(e) {
                window.webkit.messageHandlers.botguardRunner.postMessage(
                    JSON.stringify({type:'mint',error:String(e)})
                );
            });
        })();
        """

        let token = await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            self.mintCont = cont
            wv.evaluateJavaScript(js) { [weak self] _, error in
                if let error {
                    bgwvLog.notice("[BotGuardWV] mintToken evaluateJavaScript error: \(error.localizedDescription)")
                    self?.mintCont?.resume(returning: nil)
                    self?.mintCont = nil
                }
            }
        }

        if let token {
            bgwvLog.notice("[BotGuardWV] ✅ mintToken(identifier.len=\(effectiveIdentifier.count) webVD=\(self.webVisitorData.isEmpty ? "no" : "yes")) → token len=\(token.count)")
        } else {
            bgwvLog.notice("[BotGuardWV] ⚠️ mintToken(identifier.len=\(effectiveIdentifier.count) webVD=\(self.webVisitorData.isEmpty ? "no" : "yes")) → nil")
        }

        return token
    }

    // MARK: - Private: WKWebView setup

    private func launchWebView(videoId: String) {
        currentVideoId = videoId
        let contentController = WKUserContentController()
        contentController.add(self, name: "botguardRunner")

        let config = WKWebViewConfiguration()
        ResolverWebViewPolicy.configure(config)
        config.userContentController = contentController
        config.websiteDataStore = .default()

        // Pre-seed the SOCS consent cookie so YouTube doesn't serve a GDPR wall.
        let socsCookieProps: [HTTPCookiePropertyKey: Any] = [
            .name: "SOCS",   .value: "CAI",
            .domain: ".youtube.com", .path: "/",
            .secure: true,   .sameSitePolicy: "None",
            .expires: Date(timeIntervalSinceNow: 365 * 24 * 3600)
        ]
        if let socsCookie = HTTPCookie(properties: socsCookieProps) {
            config.websiteDataStore.httpCookieStore.setCookie(socsCookie)
        }

        let wv = WKWebView(frame: CGRect(x: -1, y: -1, width: 1, height: 1), configuration: config)
        ResolverWebViewPolicy.isolate(wv)
        wv.navigationDelegate = self
        // Use a desktop Safari UA so jnn-pa.googleapis.com treats this as a browser.
        wv.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
            "AppleWebKit/605.1.15 (KHTML, like Gecko) " +
            "Version/17.5 Safari/605.1.15"
        self.webView = wv

        // Load youtube.com/robots.txt — tiny page (<500ms), establishes youtube.com origin
        // so fetch() calls to jnn-pa.googleapis.com pass CORS.
        guard let pageURL = URL(string: "https://www.youtube.com/robots.txt") else {
            bgwvLog.error("[BotGuardWV] invalid robots.txt URL")
            prepareCont?.resume(returning: PrepareResult(hasMinter: false, websafeToken: nil, ttl: 3600, integrityTokenLen: 0, webVisitorData: ""))
            prepareCont = nil
            return
        }
        var request = URLRequest(url: pageURL, timeoutInterval: 15)
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        wv.load(request)

        // Safety timeout — fail after 45 s regardless.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 45_000_000_000)
            guard let self, self.prepareCont != nil else { return }
            bgwvLog.notice("[BotGuardWV] ⚠️ prepare() timed out after 45 s")
            self.prepareCont?.resume(returning: PrepareResult(
                hasMinter: false, websafeToken: nil, ttl: 3600, integrityTokenLen: 0, webVisitorData: ""
            ))
            self.prepareCont = nil
            self.teardownWebView()
        }
    }

    /// JavaScript that runs the full BotGuard WAA pipeline inside WKWebView.
    /// Runs `Create → parse → eval VM → vm.a() → asyncSnapshotFn() → GenerateIT → getMinter → WEB guide`.
    private static func pipelineJS(videoId _: String) -> String {
        let apiKey = waaAPIKey
        let reqKey = requestKey
        return """
        (async function runBotGuardInWebKit() {
            function send(data) {
                window.webkit.messageHandlers.botguardRunner.postMessage(JSON.stringify(data));
            }
            try {
                // ── Phase 1: WAA Create ─────────────────────────────────────────────────
                const createResp = await fetch(
                    'https://jnn-pa.googleapis.com/$rpc/google.internal.waa.v1.Waa/Create',
                    {
                        method: 'POST',
                        headers: {
                            'Content-Type': 'application/json+protobuf',
                            'x-goog-api-key': '\(apiKey)',
                            'x-user-agent': 'grpc-web-javascript/0.1'
                        },
                        body: JSON.stringify(['\(reqKey)'])
                    }
                );
                if (!createResp.ok) throw new Error('WAA Create HTTP ' + createResp.status);
                const outer = await createResp.json();

                // ── Parse BgUtils v3.2 descrambled challenge ────────────────────────────
                let interpreterJS = null, program = '', globalName = '';

                if (typeof outer[1] === 'string' && outer[1].length > 0) {
                    // Descramble: base64-decode → each byte + 97 (mod 256) → UTF-8 → JSON
                    const encoded = outer[1];
                    const rem = encoded.length % 4;
                    const padded = rem === 0 ? encoded : encoded + '='.repeat(4 - rem);
                    const bStr = atob(padded);
                    const bytes = new Uint8Array(bStr.length);
                    for (let i = 0; i < bStr.length; i++) bytes[i] = (bStr.charCodeAt(i) + 97) & 0xFF;
                    const inner = JSON.parse(new TextDecoder().decode(bytes));
                    program = inner[4] || '';
                    globalName = inner[5] || '';
                    const wrappedScript = Array.isArray(inner[1]) ? inner[1] : [];
                    const wrappedUrl    = Array.isArray(inner[2]) ? inner[2] : [];
                    const inlineJS = wrappedScript.find(x => typeof x === 'string' && x.length > 0);
                    if (inlineJS) {
                        interpreterJS = inlineJS;
                    } else {
                        const urlRaw = wrappedUrl.find(x => typeof x === 'string' && x.length > 0);
                        if (urlRaw) {
                            const jsURL = urlRaw.startsWith('//') ? 'https:' + urlRaw : urlRaw;
                            const r = await fetch(jsURL);
                            if (!r.ok) throw new Error('Interpreter JS fetch HTTP ' + r.status);
                            interpreterJS = await r.text();
                        }
                    }
                } else if (Array.isArray(outer[0]) && outer[0].length >= 6) {
                    // Legacy format
                    const inner = outer[0];
                    program = inner[4] || '';
                    globalName = inner[5] || '';
                    const urlRaw = (Array.isArray(inner[2]) ? inner[2] : [])
                        .find(x => typeof x === 'string' && x.length > 0);
                    if (urlRaw) {
                        const jsURL = urlRaw.startsWith('//') ? 'https:' + urlRaw : urlRaw;
                        const r = await fetch(jsURL);
                        interpreterJS = await r.text();
                    }
                }

                if (!interpreterJS || !program) throw new Error('Challenge parse failed — no interpreter JS or program');

                // ── Phase 2: Load BotGuard VM in global scope ───────────────────────────
                // Indirect eval so BotGuard's globalName is set on globalThis.
                (0, eval)(interpreterJS);

                let vm = globalName ? globalThis[globalName] : null;
                if (!vm || typeof vm.a !== 'function') {
                    for (const k of Object.keys(globalThis)) {
                        const v = globalThis[k];
                        if (v && typeof v === 'object' && typeof v.a === 'function' && k !== 'document') {
                            vm = v; break;
                        }
                    }
                }
                if (!vm || typeof vm.a !== 'function') throw new Error('BotGuard VM not found after eval');

                // ── Phase 3: vm.a() → get asyncSnapshotFn ───────────────────────────────
                let asyncSnapshotFn = null;
                await new Promise((resolve, reject) => {
                    const t = setTimeout(() => reject(new Error('vm.a() timed out')), 15000);
                    try {
                        vm.a(program, (fn0) => {
                            asyncSnapshotFn = fn0;
                            clearTimeout(t);
                            resolve();
                        }, true, undefined, () => {}, [[], []]);
                    } catch(e) { clearTimeout(t); reject(e); }
                });
                if (typeof asyncSnapshotFn !== 'function') throw new Error('asyncSnapshotFn not received');

                // ── Phase 4: asyncSnapshotFn → botguardResponse + webPoSignalOutput ─────
                const webPoSignalOutput = [];
                const botguardResponse = await new Promise((resolve, reject) => {
                    const t = setTimeout(() => reject(new Error('snapshot timed out')), 25000);
                    try {
                        asyncSnapshotFn(
                            (resp) => { clearTimeout(t); resolve(resp); },
                            [undefined, undefined, webPoSignalOutput, undefined]
                        );
                    } catch(e) { clearTimeout(t); reject(e); }
                });
                if (!botguardResponse) throw new Error('botguardResponse is empty');

                // ── Phase 5: WAA GenerateIT ─────────────────────────────────────────────
                const genResp = await fetch(
                    'https://jnn-pa.googleapis.com/$rpc/google.internal.waa.v1.Waa/GenerateIT',
                    {
                        method: 'POST',
                        headers: {
                            'Content-Type': 'application/json+protobuf',
                            'x-goog-api-key': '\(apiKey)',
                            'x-user-agent': 'grpc-web-javascript/0.1'
                        },
                        body: JSON.stringify(['\(reqKey)', botguardResponse])
                    }
                );
                if (!genResp.ok) throw new Error('WAA GenerateIT HTTP ' + genResp.status);
                const genJson = await genResp.json();

                const integrityToken  = genJson[0];  // null in JSC; hopefully non-null in WKWebView
                const websafeFallback = genJson.length > 3 ? genJson[3] : null;
                const ttl = genJson[1] || 3600;

                // ── Phase 6: getMinter → cache mintCallback ──────────────────────────────
                const getMinter = webPoSignalOutput[0];
                let hasMinter = false;

                if (typeof getMinter === 'function' && integrityToken) {
                    try {
                        // Decode integrityToken from URL-safe base64
                        const b64 = integrityToken.replace(/-/g, '+').replace(/_/g, '/');
                        const rem2 = b64.length % 4;
                        const p2 = rem2 === 0 ? b64 : b64 + '='.repeat(4 - rem2);
                        const bs2 = atob(p2);
                        const tokenBytes = new Uint8Array(bs2.length);
                        for (let i = 0; i < bs2.length; i++) tokenBytes[i] = bs2.charCodeAt(i);

                        const mintCallback = await getMinter(tokenBytes);
                        // Store for all future mintToken() calls from Swift.
                        window.__bgMintCallback = mintCallback;
                        window.__bgMintExpiry   = Date.now() + ttl * 1000;
                        hasMinter = true;
                    } catch(e) {
                        // getMinter failed — will report hasMinter=false
                    }
                }

                // ── Phase 7: WEB session visitorData (for canonical BotGuard identifier) ──
                // POST to www.youtube.com uses the WKWebView's youtube.com session cookies
                // automatically (same-origin request from robots.txt). The responseContext
                // .visitorData is the correct identifier for minting WEB BotGuard tokens —
                // it ties the minted token to the WKWebView's session, matching what the
                // CDN expects when it validates the pot= token against the session context.
                let webVisitorData = '';
                try {
                    const guideResp = await fetch('https://www.youtube.com/youtubei/v1/guide', {
                        method: 'POST',
                        headers: {
                            'Content-Type': 'application/json',
                            'X-YouTube-Client-Name': '1',
                            'X-YouTube-Client-Version': '2.20240101.00.00'
                        },
                        body: JSON.stringify({
                            context: {
                                client: {
                                    clientName: 'WEB',
                                    clientVersion: '2.20240101.00.00',
                                    gl: 'US',
                                    hl: 'en'
                                }
                            }
                        })
                    });
                    if (guideResp.ok) {
                        const guideJson = await guideResp.json();
                        webVisitorData = guideJson?.responseContext?.visitorData || '';
                    }
                } catch(e) {
                    // Guide call failed — webVisitorData stays ''
                }

                send({
                    type: 'prepare',
                    success: true,
                    hasMinter: hasMinter,
                    websafeToken: hasMinter ? null : (websafeFallback || null),
                    ttl: ttl,
                    integrityTokenLen: integrityToken ? integrityToken.length : 0,
                    webVisitorData: webVisitorData
                });

            } catch(e) {
                send({ type: 'prepare', success: false, error: String(e), webVisitorData: '' });
            }
        })();
        """
    }

    private func teardownWebView() {
        // Stop navigation but keep the script message handler and the JS context alive —
        // mintToken() needs to call window.__bgMintCallback via WKScriptMessageHandler.
        // Handlers are only removed in invalidate() when the WKWebView is fully torn down.
        webView?.navigationDelegate = nil
        webView?.stopLoading()
    }

    /// Copies WKWebView's youtube.com and google.com cookies to `HTTPCookieStorage.shared`.
    ///
    /// AVFoundation's `AVURLAsset` uses the shared HTTP cookie storage when making CDN
    /// segment requests. Propagating the WKWebView session cookies ensures the CDN sees
    /// the same YouTube session that solved the BotGuard challenge — required for `pot=`
    /// validation to pass on `rqh=1` adaptive stream URLs.
    private func propagateWebViewCookies() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
                var count = 0
                for cookie in cookies {
                    guard cookie.domain.contains("youtube.com") ||
                          cookie.domain.contains("google.com") ||
                          cookie.domain.contains("googlevideo.com") else { continue }
                    HTTPCookieStorage.shared.setCookie(cookie)
                    count += 1
                }
                bgwvLog.notice("[BotGuardWV] propagated \(count) WKWebView cookies → HTTPCookieStorage.shared")
                cont.resume()
            }
        }
    }

    /// Destroys the WKWebView entirely (call on TTL expiry or app backgrounding).
    private func invalidate() {
        mintCallbackReady = false
        mintExpiry = nil
        prepareTask = nil
        webView?.navigationDelegate = nil
        webView?.stopLoading()
        webView?.configuration.userContentController.removeAllScriptMessageHandlers()
        webView = nil
    }
}

// MARK: - WKNavigationDelegate

extension BotGuardWebViewRunner: WKNavigationDelegate {

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        bgwvLog.notice("[BotGuardWV] page loaded — injecting BotGuard pipeline JS")
        webView.evaluateJavaScript(Self.pipelineJS(videoId: currentVideoId)) { [weak self] _, error in
            if let error {
                let msg = error.localizedDescription
                // "JavaScript execution returned a result of an unsupported type" is EXPECTED
                // for async IIFEs — the IIFE returns a Promise, which WKWebView cannot
                // serialise back to Swift. This is not a failure; the real result comes via
                // WKScriptMessageHandler (botguardRunner). Log and ignore.
                if msg.contains("unsupported type") || msg.contains("Promise") || msg.contains("JSSynchronousError") {
                    bgwvLog.notice("[BotGuardWV] pipeline JS injected (async IIFE — Promise return is expected; result via WKScriptMessageHandler)")
                    return
                }
                // A genuine injection error (e.g. syntax error, WKWebView deallocated).
                bgwvLog.error("[BotGuardWV] pipeline JS injection error: \(msg)")
                self?.prepareCont?.resume(returning: PrepareResult(
                    hasMinter: false, websafeToken: nil, ttl: 3600, integrityTokenLen: 0, webVisitorData: ""
                ))
                self?.prepareCont = nil
            }
        }
    }

    public func webView(_ webView: WKWebView,
                        didFail navigation: WKNavigation!,
                        withError error: Error) {
        bgwvLog.error("[BotGuardWV] navigation failed: \(error.localizedDescription)")
        prepareCont?.resume(returning: PrepareResult(
            hasMinter: false, websafeToken: nil, ttl: 3600, integrityTokenLen: 0, webVisitorData: ""
        ))
        prepareCont = nil
    }

    public func webView(_ webView: WKWebView,
                        didFailProvisionalNavigation navigation: WKNavigation!,
                        withError error: Error) {
        bgwvLog.error("[BotGuardWV] provisional navigation failed: \(error.localizedDescription)")
        prepareCont?.resume(returning: PrepareResult(
            hasMinter: false, websafeToken: nil, ttl: 3600, integrityTokenLen: 0, webVisitorData: ""
        ))
        prepareCont = nil
    }
}

// MARK: - WKScriptMessageHandler

extension BotGuardWebViewRunner: WKScriptMessageHandler {

    public func userContentController(_ userContentController: WKUserContentController,
                                      didReceive message: WKScriptMessage) {
        guard message.name == "botguardRunner",
              let bodyStr = message.body as? String,
              let data = bodyStr.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        let msgType = json["type"] as? String ?? "unknown"

        switch msgType {
        case "prepare":
            handlePrepareMessage(json)
        case "mint":
            handleMintMessage(json)
        default:
            bgwvLog.notice("[BotGuardWV] unknown message type: \(msgType)")
        }
    }

    private func handlePrepareMessage(_ json: [String: Any]) {
        let success  = json["success"] as? Bool ?? false
        let hasMinter = json["hasMinter"] as? Bool ?? false
        let websafeToken = json["websafeToken"] as? String
        let ttl = json["ttl"] as? Int ?? 3600
        let integrityTokenLen = json["integrityTokenLen"] as? Int ?? 0
        let webVD = json["webVisitorData"] as? String ?? ""

        if success {
            bgwvLog.notice("[BotGuardWV] prepare result: hasMinter=\(hasMinter) integrityTokenLen=\(integrityTokenLen) ttl=\(ttl)s websafeToken.len=\(websafeToken?.count ?? 0) webVisitorData.len=\(webVD.count)")
        } else {
            let err = json["error"] as? String ?? "unknown"
            bgwvLog.notice("[BotGuardWV] prepare failed: \(err)")
        }

        webVisitorData = webVD

        prepareCont?.resume(returning: PrepareResult(
            hasMinter: hasMinter,
            websafeToken: websafeToken,
            ttl: ttl,
            integrityTokenLen: integrityTokenLen,
            webVisitorData: webVD
        ))
        prepareCont = nil

        teardownWebView()
    }

    private func handleMintMessage(_ json: [String: Any]) {
        if let error = json["error"] as? String {
            bgwvLog.notice("[BotGuardWV] mint error: \(error)")
            mintCont?.resume(returning: nil)
        } else if let token = json["token"] as? String, !token.isEmpty {
            mintCont?.resume(returning: token)
        } else {
            mintCont?.resume(returning: nil)
        }
        mintCont = nil
    }
}

#endif // canImport(WebKit)
