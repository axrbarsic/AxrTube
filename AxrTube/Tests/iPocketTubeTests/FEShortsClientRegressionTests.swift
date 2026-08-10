import Foundation
import Testing
@testable import iPocketTubeCore

// MARK: - FEShortsClientRegressionTests
//
// Regression tests for task #96: fetchShorts and fetchShortsMore must route
// through a client that the device-code OAuth token can ride on.
//
// NOTE (2026-05-24): YouTube deprecated the FEshorts browseId — every attempt
// (postTV, postTVCategory, WEB) returns HTTP 400, so fetchShorts was migrated
// to the search "#shorts" path, which always uses the WEB client context.
// The TVHTML5 client is only used by fetchShortsMore for legacy (un-prefixed)
// continuation tokens from older app versions.
//
// These tests intercept the outgoing URLRequest via URLProtocol and verify the
// JSON body contains the expected `clientName` for each path.

// MARK: - URLProtocol helper

/// Intercepts the first outgoing POST request and captures its JSON body.
/// Returns HTTP 400 so the caller's network path fails fast.
private final class BodyCapturingURLProtocol: URLProtocol, @unchecked Sendable {

    nonisolated(unsafe) static var capturedBody: Data?

    override class func canInit(with request: URLRequest) -> Bool {
        request.httpMethod == "POST"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // URLSession converts httpBody to httpBodyStream before handing the request
        // to URLProtocol; httpBody is always nil here.
        // Only capture the FIRST request — fetchShorts falls back to a second search
        // request when the primary browse fails, and we must not let it overwrite
        // the FEshorts browse body we already captured.
        if BodyCapturingURLProtocol.capturedBody == nil {
            if let stream = request.httpBodyStream {
                stream.open()
                var body = Data()
                let bufferSize = 4096
                let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
                defer {
                    buffer.deallocate()
                    stream.close()
                }
                // Use read-until-zero rather than hasBytesAvailable; the latter
                // can return false prematurely for in-memory streams.
                while true {
                    let count = stream.read(buffer, maxLength: bufferSize)
                    if count <= 0 { break }
                    body.append(buffer, count: count)
                }
                BodyCapturingURLProtocol.capturedBody = body
            } else if let bodyData = request.httpBody {
                // Fallback: some configurations pass the body directly in httpBody.
                BodyCapturingURLProtocol.capturedBody = bodyData
            }
        }

        // Reply with a minimal HTTP 400 response so the API call fails fast.
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 400,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

// MARK: - Tests

@Suite("FEshorts uses TV client — Regression #96", .serialized)
struct FEShortsClientRegressionTests {

    // MARK: - Helpers

    /// Returns an `InnerTubeAPI` wired to `BodyCapturingURLProtocol` via an ephemeral
    /// `URLSession`. This avoids polluting the global URLProtocol registry.
    private func makeTestAPI(authToken: String) -> InnerTubeAPI {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [BodyCapturingURLProtocol.self]
        let session = URLSession(configuration: config)
        return InnerTubeAPI(authToken: authToken, session: session)
    }

    // MARK: - fetchShorts

    /// Verifies that fetchShorts routes through the search endpoint with the
    /// WEB client, even when authenticated.
    ///
    /// FEshorts browse is retired (HTTP 400 on every client), so fetchShorts is
    /// a search "#shorts" call; search always uses the WEB client context.
    @Test("fetchShorts routes through the WEB search client")
    func fetchShortsUsesSearchClient() async throws {
        BodyCapturingURLProtocol.capturedBody = nil
        let api = makeTestAPI(authToken: "fake-tv-oauth-token")

        // The call will throw (HTTP 400 from BodyCapturingURLProtocol), which is expected.
        _ = try? await api.fetchShorts()

        let bodyData = try #require(
            BodyCapturingURLProtocol.capturedBody,
            "URLProtocol should have captured the POST body"
        )
        let json = try #require(
            try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
            "Request body must be valid JSON"
        )

        let context = json["context"] as? [String: Any]
        let clientDict = context?["client"] as? [String: Any]

        #expect(
            clientDict?["clientName"] as? String == "WEB",
            """
            fetchShorts is implemented as search "#shorts" and must use the WEB
            client context (the FEshorts browseId is retired by YouTube).
            Found clientName=\(String(describing: clientDict?["clientName"]))
            """
        )
        #expect(
            json["query"] as? String == "#shorts",
            "fetchShorts must send the #shorts search query in the body"
        )
    }

    // MARK: - fetchShortsMore

    /// Verifies that fetchShortsMore sends `clientName: "TVHTML5"`.
    ///
    /// Continuation tokens are client-scoped: a token from a TVHTML5 FEshorts
    /// response must be submitted with TVHTML5 context to work correctly.
    @Test("fetchShortsMore sends TVHTML5 clientName")
    func fetchShortsMoreSendsTVClient() async throws {
        BodyCapturingURLProtocol.capturedBody = nil
        let api = makeTestAPI(authToken: "fake-tv-oauth-token")

        _ = try? await api.fetchShortsMore(continuationToken: "test-continuation-token-12345")

        let bodyData = try #require(
            BodyCapturingURLProtocol.capturedBody,
            "URLProtocol should have captured the POST body"
        )
        let json = try #require(
            try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
            "Request body must be valid JSON"
        )

        let context = json["context"] as? [String: Any]
        let clientDict = context?["client"] as? [String: Any]

        #expect(
            clientDict?["clientName"] as? String == "TVHTML5",
            """
            fetchShortsMore must use TVHTML5 client.
            Found clientName=\(String(describing: clientDict?["clientName"]))
            """
        )
        #expect(
            json["continuation"] as? String == "test-continuation-token-12345",
            "fetchShortsMore must forward the continuation token in the body"
        )
    }
}
