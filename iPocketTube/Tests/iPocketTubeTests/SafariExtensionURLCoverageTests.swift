import Foundation
import Testing
@testable import iPocketTubeCore

// MARK: - iPocketTubeSafariExtensionURLCoverageTests
//
// Verifies parity between the URL patterns declared in
// iPocketTubeSafariExtension/manifest.json (content_scripts.matches) and
// YouTubeLinkHandler.videoID(from:).
//
// Every URL pattern that content.js intercepts must yield a non-nil video ID
// from YouTubeLinkHandler so that the ipockettube://video/<id> deep link the
// extension produces can always be round-tripped back to a video ID on the
// app side.
//
// If a new URL pattern is added to manifest.json, add a corresponding test here.

@Suite("Safari Extension URL coverage — parity with YouTubeLinkHandler")
struct iPocketTubeSafariExtensionURLCoverageTests {

    private static let testID = "dQw4w9WgXcQ"

    // MARK: - manifest.json pattern: *://www.youtube.com/watch*

    @Test("www.youtube.com/watch?v= is handled by YouTubeLinkHandler")
    func wwwWatchURL() {
        let url = URL(string: "https://www.youtube.com/watch?v=\(Self.testID)")!
        #expect(YouTubeLinkHandler.videoID(from: url) == Self.testID)
    }

    // MARK: - manifest.json pattern: *://m.youtube.com/watch*

    @Test("m.youtube.com/watch?v= is handled by YouTubeLinkHandler")
    func mobileWatchURL() {
        let url = URL(string: "https://m.youtube.com/watch?v=\(Self.testID)")!
        #expect(YouTubeLinkHandler.videoID(from: url) == Self.testID)
    }

    // MARK: - manifest.json pattern: *://www.youtube.com/shorts/*

    @Test("youtube.com/shorts/<id> is handled by YouTubeLinkHandler")
    func shortsURL() {
        let url = URL(string: "https://www.youtube.com/shorts/\(Self.testID)")!
        #expect(YouTubeLinkHandler.videoID(from: url) == Self.testID)
    }

    // MARK: - manifest.json pattern: *://music.youtube.com/watch*

    @Test("music.youtube.com/watch?v= is handled by YouTubeLinkHandler")
    func musicWatchURL() {
        let url = URL(string: "https://music.youtube.com/watch?v=\(Self.testID)")!
        #expect(YouTubeLinkHandler.videoID(from: url) == Self.testID)
    }

    // MARK: - manifest.json pattern: *://youtu.be/*

    @Test("youtu.be/<id> is handled by YouTubeLinkHandler")
    func youtuBeURL() {
        let url = URL(string: "https://youtu.be/\(Self.testID)")!
        #expect(YouTubeLinkHandler.videoID(from: url) == Self.testID)
    }

    // MARK: - Negative: non-intercepted YouTube pages must not produce false positives

    @Test("youtube.com channel page is NOT intercepted (not a match pattern)")
    func channelPageReturnsNil() {
        // content.js only matches /watch and /shorts/ — channel pages are excluded
        let url = URL(string: "https://www.youtube.com/channel/UCxxxxxxxxxxxxxx")!
        #expect(YouTubeLinkHandler.videoID(from: url) == nil)
    }

    @Test("youtube.com home page is NOT intercepted (not a match pattern)")
    func homePageReturnsNil() {
        let url = URL(string: "https://www.youtube.com/")!
        #expect(YouTubeLinkHandler.videoID(from: url) == nil)
    }
}
