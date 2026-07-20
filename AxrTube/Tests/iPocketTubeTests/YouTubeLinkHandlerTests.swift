import Foundation
import Testing
@testable import iPocketTubeCore

// MARK: - YouTubeLinkHandlerTests
//
// Tests every URL format documented in YouTubeLinkHandler.videoID(from:).
// All inputs are pure value transforms — no network, no async.

@Suite("YouTube Link Handler")
struct YouTubeLinkHandlerTests {

    // MARK: - Standard web URLs

    @Test("Standard watch URL extracts video ID")
    func watchURL() {
        let url = URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")!
        #expect(YouTubeLinkHandler.videoID(from: url) == "dQw4w9WgXcQ")
    }

    @Test("Short youtu.be URL extracts video ID")
    func shortURL() {
        let url = URL(string: "https://youtu.be/dQw4w9WgXcQ")!
        #expect(YouTubeLinkHandler.videoID(from: url) == "dQw4w9WgXcQ")
    }

    @Test("/shorts/ path extracts video ID")
    func shortsPath() {
        let url = URL(string: "https://www.youtube.com/shorts/dQw4w9WgXcQ")!
        #expect(YouTubeLinkHandler.videoID(from: url) == "dQw4w9WgXcQ")
    }

    @Test("/v/ path extracts video ID")
    func vPath() {
        let url = URL(string: "https://www.youtube.com/v/dQw4w9WgXcQ")!
        #expect(YouTubeLinkHandler.videoID(from: url) == "dQw4w9WgXcQ")
    }

    @Test("Mobile m.youtube.com watch URL extracts video ID")
    func mobileWatchURL() {
        let url = URL(string: "https://m.youtube.com/watch?v=dQw4w9WgXcQ")!
        #expect(YouTubeLinkHandler.videoID(from: url) == "dQw4w9WgXcQ")
    }

    @Test("http scheme is also supported")
    func httpSchemeSupported() {
        let url = URL(string: "http://www.youtube.com/watch?v=abc12345678")!
        #expect(YouTubeLinkHandler.videoID(from: url) == "abc12345678")
    }

    // MARK: - Deep-link schemes

    @Test("youtube:// scheme with v param extracts video ID")
    func youtubeSchemeWithVParam() {
        let url = URL(string: "youtube://watch?v=dQw4w9WgXcQ")!
        #expect(YouTubeLinkHandler.videoID(from: url) == "dQw4w9WgXcQ")
    }

    @Test("youtube:// scheme with direct video ID host extracts ID")
    func youtubeSchemeDirectID() {
        let url = URL(string: "youtube://dQw4w9WgXcQ")!
        #expect(YouTubeLinkHandler.videoID(from: url) == "dQw4w9WgXcQ")
    }

    @Test("vnd.youtube:// scheme extracts video ID")
    func vndYoutubeScheme() {
        let url = URL(string: "vnd.youtube://dQw4w9WgXcQ")!
        #expect(YouTubeLinkHandler.videoID(from: url) == "dQw4w9WgXcQ")
    }

    @Test("vnd.youtube: opaque URL extracts video ID")
    func vndYoutubeOpaque() {
        // Opaque URL: no authority component, video ID is in the path
        let url = URL(string: "vnd.youtube:dQw4w9WgXcQ")!
        #expect(YouTubeLinkHandler.videoID(from: url) == "dQw4w9WgXcQ")
    }

    // MARK: - Negative cases

    @Test("Non-YouTube URL returns nil")
    func nonYouTubeURL() {
        let url = URL(string: "https://vimeo.com/12345678901")!
        #expect(YouTubeLinkHandler.videoID(from: url) == nil)
    }

    @Test("URL without video ID returns nil")
    func urlWithoutVideoID() {
        let url = URL(string: "https://www.youtube.com/channel/UCxxxxxx")!
        #expect(YouTubeLinkHandler.videoID(from: url) == nil)
    }

    @Test("Watch URL with short-than-11-char v param returns nil")
    func shortVideoIDRejected() {
        let url = URL(string: "https://www.youtube.com/watch?v=tooshort")!
        #expect(YouTubeLinkHandler.videoID(from: url) == nil)
    }

    // MARK: - isYouTubeURL helper

    @Test("isYouTubeURL returns true for valid YouTube link")
    func isYouTubeURLTrue() {
        let url = URL(string: "https://youtu.be/dQw4w9WgXcQ")!
        #expect(YouTubeLinkHandler.isYouTubeURL(url) == true)
    }

    @Test("isYouTubeURL returns false for non-YouTube link")
    func isYouTubeURLFalse() {
        let url = URL(string: "https://google.com")!
        #expect(YouTubeLinkHandler.isYouTubeURL(url) == false)
    }

    // MARK: - ID character validation

    @Test("Video ID with underscore and hyphen is valid")
    func idWithUnderscoreAndHyphen() {
        // IDs can contain A-Z, a-z, 0-9, -, _
        let url = URL(string: "https://www.youtube.com/watch?v=A-B_CDE1234")!
        #expect(YouTubeLinkHandler.videoID(from: url) == "A-B_CDE1234")
    }

    @Test("Video ID with invalid character returns nil")
    func idWithInvalidCharacter() {
        let url = URL(string: "https://www.youtube.com/watch?v=AAAAAAA!!!!")!
        #expect(YouTubeLinkHandler.videoID(from: url) == nil)
    }
}
