import Foundation
import Testing
@testable import iPocketTubeCore

// MARK: - ChannelHandleResolutionTests
//
// Regression tests for task #185: subscribed channels stored with @handle format
// fail to open because navigation/resolve_url does not always return a browseId
// in the expected key path.
//
// Fix: resolveChannelHandle now catches unexpected responses and falls through to
// passing the handle directly as a browseId to /browse. parseChannel then extracts
// the canonical UC… channelId from channelMetadataRenderer.externalId.
//
// These tests inject a URLProtocol that returns:
//  - For navigation/resolve_url: an empty/unexpected JSON body (simulating the failure)
//  - For browse: a valid channel browse response with channelMetadataRenderer.externalId
//
// Verified behaviour:
//  1. fetchChannel(@handle) succeeds despite resolve_url returning no browseId.
//  2. The returned channel.id is the UC… ID from externalId, not the @handle string.

// MARK: - URLProtocol for multi-endpoint response injection

/// A URLProtocol that serves different JSON responses per URL path.
private final class MultiEndpointURLProtocol: URLProtocol, @unchecked Sendable {

    // Configurable responses keyed by URL path suffix (e.g. "navigation/resolve_url").
    nonisolated(unsafe) static var responses: [String: (statusCode: Int, body: [String: Any])] = [:]

    override class func canInit(with request: URLRequest) -> Bool {
        request.httpMethod == "POST"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url?.absoluteString ?? ""
        // Match the longest registered suffix that the URL ends with.
        let match = Self.responses
            .filter { url.contains($0.key) }
            .max(by: { $0.key.count < $1.key.count })
        let (statusCode, body) = match.map { ($0.value.statusCode, $0.value.body) } ?? (200, [:])
        let responseData = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
        let httpResponse = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: responseData)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

// MARK: - Tests

@Suite("Channel @handle resolution fallback (#185)", .serialized)
struct ChannelHandleResolutionTests {

    // MARK: - Helpers

    private static let canonicalChannelId = "UCWZDfaQEe-JT-3SKPHLnX5Q"
    private static let channelHandle = "@nieuwsuur"

    /// Minimal valid channel browse response containing channelMetadataRenderer.externalId.
    private static var channelBrowseResponse: [String: Any] {
        [
            "header": [
                "c4TabbedHeaderRenderer": [
                    "title": "Nieuwsuur",
                    "avatar": ["thumbnails": [["url": "https://example.com/thumb.jpg"]]],
                    "subscriberCountText": ["simpleText": "1.2M subscribers"]
                ]
            ],
            "metadata": [
                "channelMetadataRenderer": [
                    "externalId": canonicalChannelId,
                    "title": "Nieuwsuur",
                    "channelUrl": "https://www.youtube.com/channel/\(canonicalChannelId)"
                ]
            ],
            "contents": [String: Any]()  // empty, no video grid needed for channel identity test
        ]
    }

    private func makeAPI() -> InnerTubeAPI {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MultiEndpointURLProtocol.self]
        let session = URLSession(configuration: config)
        return InnerTubeAPI(authToken: nil, session: session)
    }

    // MARK: - resolve_url failure → browse fallback → correct channel.id

    /// When navigation/resolve_url does not return a browseId (unexpected response format,
    /// consent wall, HTTP error), fetchChannel must still succeed by falling back to
    /// passing the @handle directly as browseId and extracting externalId from the
    /// browse response. The returned Channel.id must be the UC… ID, not the handle.
    @Test("fetchChannel(@handle) succeeds when resolve_url returns no browseId")
    func fetchChannelWithHandleFallsBackToBrowse() async throws {
        MultiEndpointURLProtocol.responses = [
            // resolve_url: unexpected response (no "endpoint" key)
            "navigation/resolve_url": (200, ["error": ["code": 400, "message": "consent required"]]),
            // browse: valid channel response with externalId
            "browse": (200, Self.channelBrowseResponse)
        ]
        let api = makeAPI()

        let (channel, _) = try await api.fetchChannel(channelId: Self.channelHandle)

        #expect(
            channel.id == Self.canonicalChannelId,
            """
            channel.id should be the UC… externalId from channelMetadataRenderer, not the handle.
            Got: \(channel.id)
            Expected: \(Self.canonicalChannelId)
            """
        )
        #expect(channel.title == "Nieuwsuur")
    }

    // MARK: - resolve_url success → canonical ID used directly

    /// When navigation/resolve_url succeeds and returns a browseId, it must be used
    /// and parseChannel should see it confirmed by externalId in the browse response.
    @Test("fetchChannel(@handle) uses browseId from resolve_url when available")
    func fetchChannelUsesResolveUrlWhenSuccessful() async throws {
        MultiEndpointURLProtocol.responses = [
            // resolve_url: returns the canonical browseId
            "navigation/resolve_url": (200, [
                "endpoint": [
                    "browseEndpoint": ["browseId": Self.canonicalChannelId]
                ]
            ]),
            // browse: valid channel response
            "browse": (200, Self.channelBrowseResponse)
        ]
        let api = makeAPI()

        let (channel, _) = try await api.fetchChannel(channelId: Self.channelHandle)

        #expect(channel.id == Self.canonicalChannelId)
        #expect(channel.title == "Nieuwsuur")
    }

    // MARK: - resolve_url returns urlEndpoint (no browseId) → search fallback

    /// Regression test for GitHub issue #79: `@nieuwsuur` redirects to a legacy
    /// custom-URL slug ("/Nieuwsuur") rather than a true `@handle`. Confirmed
    /// live against YouTube: resolve_url returns a `urlEndpoint` (not
    /// `browseEndpoint`, no error) for this channel, and `/browse` with
    /// `browseId: "@nieuwsuur"` then returns HTTP 400 — the old fallback
    /// ("pass the handle through unchanged") does not hold here. The fix adds
    /// a search-based fallback: search for the handle and match a
    /// `channelRenderer` result's `canonicalBaseUrl` against it.
    @Test("fetchChannel(@handle) falls back to search when resolve_url returns a urlEndpoint")
    func fetchChannelFallsBackToSearchWhenResolveUrlReturnsUrlEndpoint() async throws {
        let searchResponse: [String: Any] = [
            "contents": [
                "twoColumnSearchResultsRenderer": [
                    "primaryContents": [
                        "sectionListRenderer": [
                            "contents": [
                                [
                                    "itemSectionRenderer": [
                                        "contents": [
                                            [
                                                "channelRenderer": [
                                                    "channelId": Self.canonicalChannelId,
                                                    "title": ["simpleText": "Nieuwsuur"],
                                                    "longBylineText": [
                                                        "runs": [
                                                            [
                                                                "navigationEndpoint": [
                                                                    "browseEndpoint": [
                                                                        "browseId": Self.canonicalChannelId,
                                                                        "canonicalBaseUrl": "/@nieuwsuur"
                                                                    ]
                                                                ]
                                                            ]
                                                        ]
                                                    ]
                                                ]
                                            ]
                                        ]
                                    ]
                                ]
                            ]
                        ]
                    ]
                ]
            ]
        ]
        MultiEndpointURLProtocol.responses = [
            // resolve_url: urlEndpoint instead of browseEndpoint — no browseId, no error.
            "navigation/resolve_url": (200, [
                "endpoint": [
                    "urlEndpoint": ["url": "https://www.youtube.com/Nieuwsuur"]
                ]
            ]),
            "search": (200, searchResponse),
            "browse": (200, Self.channelBrowseResponse)
        ]
        let api = makeAPI()

        let (channel, _) = try await api.fetchChannel(channelId: Self.channelHandle)

        #expect(channel.id == Self.canonicalChannelId)
        #expect(channel.title == "Nieuwsuur")
    }

    // MARK: - UC… ID bypasses handle resolution entirely

    /// When the channelId is already in UC… format, no resolve_url call is made and
    /// the browse proceeds directly. This ensures the fix doesn't regress normal UC ID paths.
    @Test("fetchChannel(UC…) does not call resolve_url, returns correct channel")
    func fetchChannelWithUCIdSkipsResolution() async throws {
        // Only register a browse response — if resolve_url is called, it would
        // return HTTP 500 which would surface as an APIError and fail the test.
        MultiEndpointURLProtocol.responses = [
            "navigation/resolve_url": (500, ["error": "should not be called"]),
            "browse": (200, Self.channelBrowseResponse)
        ]
        let api = makeAPI()

        // Should succeed without calling resolve_url.
        let (channel, _) = try await api.fetchChannel(channelId: Self.canonicalChannelId)

        #expect(channel.id == Self.canonicalChannelId)
    }
}
