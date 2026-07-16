import Foundation
import Testing
@testable import iPocketTubeCore

// MARK: - BotGuardClientTests
//
// Verifies BotGuardClient's PO token generation pipeline using a fake BotGuard
// interpreter VM and a URLProtocol-backed mock for the WAA API endpoints.
//
// The fake VM mirrors the real BotGuard contract without doing any real attestation:
//   vm.a(program, vmFnCallback, …)    → calls vmFnCallback(asyncSnapshotFn, …)
//   asyncSnapshotFn(callback, params) → sets params[2][0] = getMinter, calls callback("bg-response")
//   getMinter(integrityBytes)         → returns mintCallback (or Promise<mintCallback>)
//   mintCallback(contentBytes)        → returns Uint8Array([1, 2, 3])
//
// Expected pipeline output:
//   Integrity token input : "AAEC" (base64 of [0,1,2])
//   Mint result           : Uint8Array([1,2,3])
//   Final token           : "AQID" (base64 of [1,2,3])

// Serialized because WAARouterProtocol.routes is shared mutable class-level state;
// parallel tests would race on it between fetchChallenge() and fetchIntegrityTokenSync().
@Suite("BotGuardClient", .serialized)
struct BotGuardClientTests {

    // MARK: - Fake interpreter JS (synchronous getMinter)

    /// Minimal BotGuard interpreter that mimics the real VM API.
    /// getMinter is synchronous — returns a plain function, not a Promise.
    private static let fakeInterpreterJS = """
    (function() {
        globalThis.TestBotGuardVM = {
            a: function(program, vmFnCallback, flag, undef, noop, initPair) {
                vmFnCallback(
                    /* asyncSnapshotFn */
                    function(snapshotCallback, params) {
                        var signalOutput = params[2];
                        // Install getMinter at signalOutput[0]
                        signalOutput[0] = function getMinter(integrityBytes) {
                            return function mintCallback(contentBytes) {
                                return new Uint8Array([1, 2, 3]);
                            };
                        };
                        snapshotCallback("test-bg-response");
                    },
                    function() {}, /* shutdownFn */
                    function() {}, /* passFn */
                    function() {}  /* checkCameraFn */
                );
                return [null]; /* initResult — not a Promise */
            }
        };
    })();
    """

    /// Same as above, but getMinter returns Promise<mintCallback> instead of mintCallback directly.
    /// Exercises the microtask-pump path in resolvePromise().
    private static let fakeInterpreterJSPromiseMinter = """
    (function() {
        globalThis.TestBotGuardVM = {
            a: function(program, vmFnCallback, flag, undef, noop, initPair) {
                vmFnCallback(
                    function(snapshotCallback, params) {
                        var signalOutput = params[2];
                        signalOutput[0] = function getMinter(integrityBytes) {
                            return Promise.resolve(function mintCallback(contentBytes) {
                                return new Uint8Array([7, 8, 9]);
                            });
                        };
                        snapshotCallback("test-bg-response-promise");
                    },
                    function() {}, function() {}, function() {}
                );
                return [null];
            }
        };
    })();
    """

    /// vm.a() returns [Promise, ...] instead of [null, ...] — exercises the await-on-initResult path.
    private static let fakeInterpreterJSPromiseInit = """
    (function() {
        globalThis.TestBotGuardVM = {
            a: function(program, vmFnCallback, flag, undef, noop, initPair) {
                vmFnCallback(
                    function(snapshotCallback, params) {
                        var signalOutput = params[2];
                        signalOutput[0] = function(intBytes) {
                            return function(cBytes) { return new Uint8Array([1, 2, 3]); };
                        };
                        snapshotCallback("test-bg-response-preinit");
                    },
                    function() {}, function() {}, function() {}
                );
                // Return a pre-resolved Promise as initResult[0]
                return [Promise.resolve(undefined)];
            }
        };
    })();
    """

    // MARK: - Helpers

    private func makeSession(routes: [String: Data]) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        WAARouterProtocol.routes = routes
        config.protocolClasses = [WAARouterProtocol.self]
        return URLSession(configuration: config)
    }

    /// Scrambles an inner challenge array into the WAA Create outer[1] string format (BgUtils v3.2+).
    /// Algorithm: JSON-encode → subtract 97 from every byte (mod 256) → base64-encode.
    private func scramble(_ inner: [Any]) throws -> String {
        let jsonData = try JSONSerialization.data(withJSONObject: inner)
        return Data(jsonData.map { $0 &- 97 }).base64EncodedString()
    }

    private func waaCreatePayload(interpreterValue: String) throws -> Data {
        // Current WAA Create format (BgUtils v3.2+):
        // outer[0] = requestKey echo
        // outer[1] = scrambled base64 string containing the inner challenge array
        //
        // Inner array layout:
        // [messageId, wrappedScript, wrappedUrl, interpreterHash, program, globalName]
        //   wrappedScript: array — first non-empty String is the inline interpreter JS
        //   wrappedUrl:    array — first non-empty String is the URL to fetch interpreter JS from
        let isURL = interpreterValue.hasPrefix("http") || interpreterValue.hasPrefix("//")
        let wrappedScript: [Any] = isURL ? [] : [interpreterValue]
        let wrappedUrl: [Any]    = isURL ? [interpreterValue] : []
        let inner: [Any] = ["msgId001", wrappedScript, wrappedUrl, "hash-abc", "program-bytes", "TestBotGuardVM"]
        let payload: [Any] = ["O43z0dpjhgX20SCx4KAo", try scramble(inner)]
        return try JSONSerialization.data(withJSONObject: payload)
    }

    private func waaCreatePayloadNested(interpreterValue: String) throws -> Data {
        // Tests wrappedScript with mixed elements (including NSNull) — verifies compactMap skips nulls.
        let inner: [Any] = ["msgId001", [NSNull(), interpreterValue], [], "hash-abc", "program-bytes", "TestBotGuardVM"]
        let payload: [Any] = ["O43z0dpjhgX20SCx4KAo", try scramble(inner)]
        return try JSONSerialization.data(withJSONObject: payload)
    }

    /// WAA GenerateIT response: [integrityTokenB64, ttlSeconds, mintThreshold, websafeFallbackToken]
    /// Real API shape: [String|null, Int, Int, String|null] — 4 elements.
    /// "AAEC" = base64([0, 1, 2]); NSNull() at [3] since happy-path tests use the getMinter flow.
    private func waaGenerateITPayload() throws -> Data {
        try JSONSerialization.data(withJSONObject: ["AAEC", 3600, 1, NSNull()] as [Any])
    }

    // Derived from the same URL constants the client uses so the key always matches exactly.
    private static let waaCreateURL   = URL(string: "https://jnn-pa.googleapis.com/$rpc/google.internal.waa.v1.Waa/Create")!.absoluteString
    private static let waaGenerateURL = URL(string: "https://jnn-pa.googleapis.com/$rpc/google.internal.waa.v1.Waa/GenerateIT")!.absoluteString

    // MARK: - Happy path

    @Test("token(for:) returns 'AQID' with synchronous getMinter and inline interpreter JS")
    func tokenWithInlineInterpreterSync() async throws {
        var routes: [String: Data] = [:]
        routes[Self.waaCreateURL]    = try waaCreatePayload(interpreterValue: Self.fakeInterpreterJS)
        routes[Self.waaGenerateURL]  = try waaGenerateITPayload()

        let client = BotGuardClient(session: makeSession(routes: routes))
        let token = try await client.token(for: "dQw4w9WgXcQ")

        // Mint returns Uint8Array([1,2,3]) → base64 = "AQID"
        #expect(token == "AQID")
    }

    @Test("token(for:) returns valid base64 with URL-based interpreter JS")
    func tokenWithURLInterpreterJS() async throws {
        let interpreterURL = "https://www.gstatic.com/botguard/fake_bg.js"
        var routes: [String: Data] = [:]
        routes[Self.waaCreateURL]   = try waaCreatePayload(interpreterValue: interpreterURL)
        routes[interpreterURL]       = Self.fakeInterpreterJS.data(using: .utf8)!
        routes[Self.waaGenerateURL] = try waaGenerateITPayload()

        let client = BotGuardClient(session: makeSession(routes: routes))
        let token = try await client.token(for: "SomeVideoId")

        #expect(token == "AQID")
        #expect(Data(base64Encoded: token) != nil)
    }

    @Test("token(for:) resolves Promise-returning getMinter via microtask pump → 'BwgJ'")
    func tokenWithPromiseMinter() async throws {
        var routes: [String: Data] = [:]
        routes[Self.waaCreateURL]   = try waaCreatePayload(interpreterValue: Self.fakeInterpreterJSPromiseMinter)
        routes[Self.waaGenerateURL] = try waaGenerateITPayload()

        let client = BotGuardClient(session: makeSession(routes: routes))
        let token = try await client.token(for: "promise-video")

        // Mint returns Uint8Array([7,8,9]) → base64 = "BwgJ"
        #expect(token == "BwgJ")
    }

    @Test("token(for:) handles vm.a() returning pre-resolved Promise as initResult[0]")
    func tokenWithPromiseInitResult() async throws {
        var routes: [String: Data] = [:]
        routes[Self.waaCreateURL]   = try waaCreatePayload(interpreterValue: Self.fakeInterpreterJSPromiseInit)
        routes[Self.waaGenerateURL] = try waaGenerateITPayload()

        let client = BotGuardClient(session: makeSession(routes: routes))
        let token = try await client.token(for: "init-promise-video")

        #expect(token == "AQID")
    }

    // MARK: - Response structure variants

    @Test("nested challenge response outer[1] = [[...]] is parsed correctly")
    func parsesNestedChallengeResponse() async throws {
        var routes: [String: Data] = [:]
        routes[Self.waaCreateURL]   = try waaCreatePayloadNested(interpreterValue: Self.fakeInterpreterJS)
        routes[Self.waaGenerateURL] = try waaGenerateITPayload()

        let client = BotGuardClient(session: makeSession(routes: routes))
        let token = try await client.token(for: "nested-vid")

        #expect(token == "AQID")
    }

    @Test("// -prefixed interpreter URL is normalised to https://")
    func protocolRelativeInterpreterURL() async throws {
        let bareURL    = "//www.gstatic.com/botguard/proto_relative.js"
        let httpsURL   = "https://www.gstatic.com/botguard/proto_relative.js"
        var routes: [String: Data] = [:]
        routes[Self.waaCreateURL]  = try waaCreatePayload(interpreterValue: bareURL)
        routes[httpsURL]            = Self.fakeInterpreterJS.data(using: .utf8)!
        routes[Self.waaGenerateURL] = try waaGenerateITPayload()

        let client = BotGuardClient(session: makeSession(routes: routes))
        let token = try await client.token(for: "proto-rel-vid")

        #expect(token == "AQID")
    }

    // MARK: - Error paths

    @Test("token(for:) throws when WAA Create request fails")
    func throwsOnWAACreateNetworkError() async {
        // Empty routes → every request fails with URLError
        WAARouterProtocol.routes = [:]
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [WAARouterProtocol.self]
        let client = BotGuardClient(session: URLSession(configuration: config))

        await #expect(throws: (any Error).self) {
            try await client.token(for: "any-vid")
        }
    }

    @Test("token(for:) throws on non-JSON WAA Create response")
    func throwsOnMalformedWAACreateBody() async throws {
        var routes: [String: Data] = [:]
        routes[Self.waaCreateURL] = "not json at all".data(using: .utf8)!

        let client = BotGuardClient(session: makeSession(routes: routes))

        await #expect(throws: (any Error).self) {
            try await client.token(for: "any-vid")
        }
    }

    @Test("token(for:) throws when WAA Create outer array has wrong structure")
    func throwsOnWrongOuterStructure() async throws {
        // Valid JSON but not the expected [requestKey, [...]] structure
        let bad = try JSONSerialization.data(withJSONObject: ["just", "strings"])
        var routes: [String: Data] = [:]
        routes[Self.waaCreateURL] = bad

        let client = BotGuardClient(session: makeSession(routes: routes))

        await #expect(throws: (any Error).self) {
            try await client.token(for: "any-vid")
        }
    }

    @Test("token(for:) throws when inner array has fewer than 6 elements")
    func throwsOnShortInnerArray() async throws {
        // Scrambled inner array with only 4 elements — parseInnerArray requires ≥6
        let shortInner: [Any] = ["msgId", [], [], "hash"]
        let bad = try JSONSerialization.data(withJSONObject: [
            "O43z0dpjhgX20SCx4KAo",
            scramble(shortInner)
        ] as [Any])
        var routes: [String: Data] = [:]
        routes[Self.waaCreateURL] = bad

        let client = BotGuardClient(session: makeSession(routes: routes))

        await #expect(throws: (any Error).self) {
            try await client.token(for: "any-vid")
        }
    }

    @Test("token(for:) throws when VM globalName is absent from JSContext global scope")
    func throwsWhenGlobalNameNotFound() async throws {
        // Interpreter JS defines the wrong name (not "TestBotGuardVM")
        let wrongNameJS = "(function() { globalThis.NotTheRightName = { a: function(){return[null];} }; })();"
        var routes: [String: Data] = [:]
        routes[Self.waaCreateURL]  = try waaCreatePayload(interpreterValue: wrongNameJS)
        routes[Self.waaGenerateURL] = try waaGenerateITPayload()

        let client = BotGuardClient(session: makeSession(routes: routes))

        await #expect(throws: (any Error).self) {
            try await client.token(for: "bad-vm-vid")
        }
    }

    @Test("token(for:) throws when asyncSnapshotFn never sets snapshotCallback")
    func throwsWhenSnapshotFnNeverCallsCallback() async throws {
        // asyncSnapshotFn does NOT call snapshotCallback → botguardResponse stays nil
        let noCallbackJS = """
        (function() {
            globalThis.TestBotGuardVM = {
                a: function(p, cb) {
                    cb(function(snCb, params) { /* intentionally never calls snCb */ },
                       function(){}, function(){}, function(){});
                    return [null];
                }
            };
        })();
        """
        var routes: [String: Data] = [:]
        routes[Self.waaCreateURL]   = try waaCreatePayload(interpreterValue: noCallbackJS)
        routes[Self.waaGenerateURL] = try waaGenerateITPayload()

        let client = BotGuardClient(session: makeSession(routes: routes))

        await #expect(throws: (any Error).self) {
            try await client.token(for: "no-cb-vid")
        }
    }

    @Test("token(for:) throws when WAA GenerateIT network request fails")
    func throwsOnGenerateITNetworkError() async throws {
        var routes: [String: Data] = [:]
        routes[Self.waaCreateURL] = try waaCreatePayload(interpreterValue: Self.fakeInterpreterJS)
        // No route for GenerateIT → network error

        let client = BotGuardClient(session: makeSession(routes: routes))

        await #expect(throws: (any Error).self) {
            try await client.token(for: "gen-fail-vid")
        }
    }

    @Test("token(for:) throws when GenerateIT returns non-array JSON")
    func throwsOnGenerateITNonArrayJSON() async throws {
        var routes: [String: Data] = [:]
        routes[Self.waaCreateURL]   = try waaCreatePayload(interpreterValue: Self.fakeInterpreterJS)
        routes[Self.waaGenerateURL] = try JSONSerialization.data(withJSONObject: ["key": "val"])

        let client = BotGuardClient(session: makeSession(routes: routes))

        await #expect(throws: (any Error).self) {
            try await client.token(for: "bad-gen-vid")
        }
    }

    @Test("token(for:) throws when integrityToken base64 is invalid")
    func throwsOnInvalidIntegrityTokenBase64() async throws {
        var routes: [String: Data] = [:]
        routes[Self.waaCreateURL]   = try waaCreatePayload(interpreterValue: Self.fakeInterpreterJS)
        // "!!!" is not valid base64
        routes[Self.waaGenerateURL] = try JSONSerialization.data(withJSONObject: ["!!!", 3600, 1] as [Any])

        let client = BotGuardClient(session: makeSession(routes: routes))

        await #expect(throws: (any Error).self) {
            try await client.token(for: "bad-it-vid")
        }
    }

    @Test("token(for:) throws when getMinter is not set in webPoSignalOutput")
    func throwsWhenGetMinterNotSet() async throws {
        // VM never sets signalOutput[0]
        let noMinterJS = """
        (function() {
            globalThis.TestBotGuardVM = {
                a: function(p, cb) {
                    cb(function(snCb, params) {
                        // Signal output left empty
                        snCb("bg-response");
                    }, function(){}, function(){}, function(){});
                    return [null];
                }
            };
        })();
        """
        var routes: [String: Data] = [:]
        routes[Self.waaCreateURL]   = try waaCreatePayload(interpreterValue: noMinterJS)
        routes[Self.waaGenerateURL] = try waaGenerateITPayload()

        let client = BotGuardClient(session: makeSession(routes: routes))

        await #expect(throws: (any Error).self) {
            try await client.token(for: "no-minter-vid")
        }
    }

    // MARK: - BotGuardError descriptions

    @Test("BotGuardError descriptions contain the right prefix")
    func errorDescriptions() {
        #expect(BotGuardError.challengeFailed("x").description.hasPrefix("BotGuard challenge fetch failed"))
        #expect(BotGuardError.challengeParseError("x").description.hasPrefix("BotGuard challenge parse error"))
        #expect(BotGuardError.jsFailed("x").description.hasPrefix("BotGuard JS error"))
        #expect(BotGuardError.integrityTokenFailed("x").description.hasPrefix("BotGuard integrity token failed"))
        #expect(BotGuardError.mintFailed("x").description.hasPrefix("BotGuard mint failed"))
    }
}

// MARK: - Live Integration

/// Live end-to-end test using real YouTube WAA API.
/// Skipped by default — set BG_LIVE_TEST=1 env var to enable.
@Suite("BotGuardClient Live", .serialized)
struct BotGuardClientLiveTests {
    /// Verifies the full BotGuard pipeline runs end-to-end and produces a non-empty PO token.
    ///
    /// Architecture note: the WAA GenerateIT server returns json[0]=null for JSC environments
    /// (the BotGuard VM clones arguments so Proxy traps on webPoSignalOutput never fire, and
    /// getMinter is never set). The websafe fallback token (json[3]) is the expected result
    /// for this environment and IS a valid PO token accepted by YouTube.
    @Test("Live pipeline: websafe fallback path produces a valid PO token")
    func livePipelineWebsafeFallback() async throws {
        guard ProcessInfo.processInfo.environment["BG_LIVE_TEST"] == "1" else {
            return  // skip unless explicitly opted in
        }
        let client = BotGuardClient()
        let token = try await client.token(for: "LSMQ3U1Thzw")
        // Websafe fallback path: getMinter is not set (VM clones args, Proxy never fires),
        // integrityToken is nil (WAA returns json[0]=null for JSC), websafe fallback is used.
        #expect(token.count > 0, "Token should be non-empty")
        #expect(client.lastRunHasMinter == false, "Expected websafe fallback path — getMinter is not set in JSC environment")
        #expect(client.lastRunIntegrityTokenLen == 0, "Expected json[0]=null from WAA server (JSC environment)")
    }
}

// MARK: - WAARouterProtocol

/// URLProtocol that serves pre-registered Data for matching URL strings.
/// Fails all unregistered URLs with URLError(.fileDoesNotExist).
private final class WAARouterProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var routes: [String: Data] = [:]

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let key = request.url?.absoluteString ?? ""
        if let data = Self.routes[key] {
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200,
                                       httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } else {
            client?.urlProtocol(self, didFailWithError: URLError(.fileDoesNotExist))
        }
    }

    override func stopLoading() {}
}
