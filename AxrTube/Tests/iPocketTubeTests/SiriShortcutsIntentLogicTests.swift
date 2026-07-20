import Foundation
import Testing
@testable import iPocketTubeCore

// MARK: - SiriShortcutsIntentLogicTests
//
// Tests the URL validation contract that `OpenYouTubeVideoIntent.perform()`
// relies on. The intent delegates video-ID extraction to
// `YouTubeLinkHandler.videoID(from:)` and then constructs a
// `ipockettube://video/<id>` deep link. Both steps are pure value transforms
// and are tested here independently of UIKit or AppIntents.
//
// These tests document the exact set of URL formats the intent accepts and the
// deep-link URL structure that `AppEntry.handleOpenURL` expects to receive.

@Suite("Siri Shortcut Intent — URL validation contract")
struct SiriShortcutsIntentLogicTests {

    // MARK: - URLs the intent accepts (videoID is non-nil → intent proceeds)

    @Test("Standard watch URL is accepted by the intent")
    func acceptsStandardWatchURL() {
        let url = URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")!
        #expect(YouTubeLinkHandler.videoID(from: url) != nil)
    }

    @Test("youtu.be short link is accepted by the intent")
    func acceptsShortLink() {
        let url = URL(string: "https://youtu.be/dQw4w9WgXcQ")!
        #expect(YouTubeLinkHandler.videoID(from: url) != nil)
    }

    @Test("/shorts/ path is accepted by the intent")
    func acceptsShortsPath() {
        let url = URL(string: "https://www.youtube.com/shorts/dQw4w9WgXcQ")!
        #expect(YouTubeLinkHandler.videoID(from: url) != nil)
    }

    @Test("Mobile m.youtube.com URL is accepted by the intent")
    func acceptsMobileURL() {
        let url = URL(string: "https://m.youtube.com/watch?v=dQw4w9WgXcQ")!
        #expect(YouTubeLinkHandler.videoID(from: url) != nil)
    }

    // MARK: - URLs the intent rejects (videoID is nil → intent throws .notYouTubeURL)

    @Test("Non-YouTube URL is rejected — intent would throw notYouTubeURL")
    func rejectsNonYouTubeURL() {
        let url = URL(string: "https://vimeo.com/123456789")!
        #expect(YouTubeLinkHandler.videoID(from: url) == nil)
    }

    @Test("YouTube channel URL is rejected — no video ID to extract")
    func rejectsChannelURL() {
        let url = URL(string: "https://www.youtube.com/channel/UCxxxxxx")!
        #expect(YouTubeLinkHandler.videoID(from: url) == nil)
    }

    @Test("URL with a too-short video ID is rejected")
    func rejectsTooShortVideoID() {
        let url = URL(string: "https://www.youtube.com/watch?v=tooshort")!
        #expect(YouTubeLinkHandler.videoID(from: url) == nil)
    }

    // MARK: - Deep link URL format

    // The intent builds `ipockettube://video/<id>` after extracting a valid ID.
    // These tests verify that the resulting URL has the exact scheme/host/path
    // structure that `AppEntry.handleOpenURL` expects.

    @Test("Deep link URL built from extracted ID has correct scheme")
    func deepLinkURLScheme() throws {
        let url = URL(string: "https://youtu.be/dQw4w9WgXcQ")!
        let videoID = try #require(YouTubeLinkHandler.videoID(from: url))
        let deepLink = try #require(URL(string: "ipockettube://video/\(videoID)"))
        #expect(deepLink.scheme == "ipockettube")
    }

    @Test("Deep link URL built from extracted ID has correct host")
    func deepLinkURLHost() throws {
        let url = URL(string: "https://youtu.be/dQw4w9WgXcQ")!
        let videoID = try #require(YouTubeLinkHandler.videoID(from: url))
        let deepLink = try #require(URL(string: "ipockettube://video/\(videoID)"))
        #expect(deepLink.host == "video")
    }

    @Test("Deep link URL preserves the extracted video ID in its path")
    func deepLinkURLPath() throws {
        let url = URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")!
        let videoID = try #require(YouTubeLinkHandler.videoID(from: url))
        let deepLink = try #require(URL(string: "ipockettube://video/\(videoID)"))
        let pathID = deepLink.pathComponents.filter { $0 != "/" }.first
        #expect(pathID == videoID)
    }

    @Test("Deep link URL round-trips: ID in → same ID out")
    func deepLinkRoundTrip() throws {
        let inputURL = URL(string: "https://youtu.be/dQw4w9WgXcQ")!
        let videoID = try #require(YouTubeLinkHandler.videoID(from: inputURL))

        let deepLink = try #require(URL(string: "ipockettube://video/\(videoID)"))

        // Simulate AppEntry.handleOpenURL extraction
        let scheme = deepLink.scheme?.lowercased() ?? ""
        let host   = deepLink.host?.lowercased() ?? ""
        let pathID = deepLink.pathComponents.filter { $0 != "/" }.first ?? ""

        #expect(scheme == "ipockettube")
        #expect(host   == "video")
        #expect(pathID == "dQw4w9WgXcQ")
    }
}
