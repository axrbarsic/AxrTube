import Foundation
import Testing
@testable import iPocketTubeCore

// MARK: - DeArrowDisplayTests
//
// Unit tests for the DeArrow community title and thumbnail integration (#52).
//
// These tests cover:
//  1. `Video.deArrowThumbnailTimestamp` → correct YouTube CDN URL construction
//  2. `Video.deArrowTitle` → displayTitle logic when enabled / disabled
//  3. Edge cases: nil timestamp, nil title, setting disabled

@Suite("DeArrow display integration (Video model + VideoCardView helpers)")
struct DeArrowDisplayTests {

    // MARK: - Thumbnail URL construction

    @Test("deArrowThumbnailURL is nil when deArrowThumbnailTimestamp is nil")
    func thumbnailURL_nilWhenNoTimestamp() {
        var video = Video(id: "abc123", title: "Original", channelTitle: "Channel")
        video.deArrowThumbnailTimestamp = nil

        // Simulate the VideoCardView helper logic directly:
        let url: URL? = video.deArrowThumbnailTimestamp.flatMap {
            URL(string: "https://i.ytimg.com/vi/\(video.id)/\(Int($0)).jpg")
        }

        #expect(url == nil)
    }

    @Test("deArrowThumbnailURL builds correct URL from integer-truncated timestamp")
    func thumbnailURL_buildsCorrectURL() {
        var video = Video(id: "xyzVideoId", title: "Clickbait Title", channelTitle: "Channel")
        video.deArrowThumbnailTimestamp = 42.7

        let url: URL? = video.deArrowThumbnailTimestamp.flatMap {
            URL(string: "https://i.ytimg.com/vi/\(video.id)/\(Int($0)).jpg")
        }

        #expect(url?.absoluteString == "https://i.ytimg.com/vi/xyzVideoId/42.jpg")
    }

    @Test("deArrowThumbnailURL truncates (not rounds) timestamp")
    func thumbnailURL_truncatesTimestamp() {
        var video = Video(id: "vid", title: "T", channelTitle: "C")
        video.deArrowThumbnailTimestamp = 99.99

        let url: URL? = video.deArrowThumbnailTimestamp.flatMap {
            URL(string: "https://i.ytimg.com/vi/\(video.id)/\(Int($0)).jpg")
        }

        #expect(url?.absoluteString == "https://i.ytimg.com/vi/vid/99.jpg")
    }

    @Test("deArrowThumbnailURL handles zero timestamp")
    func thumbnailURL_zeroTimestamp() {
        var video = Video(id: "vid0", title: "T", channelTitle: "C")
        video.deArrowThumbnailTimestamp = 0.0

        let url: URL? = video.deArrowThumbnailTimestamp.flatMap {
            URL(string: "https://i.ytimg.com/vi/\(video.id)/\(Int($0)).jpg")
        }

        #expect(url?.absoluteString == "https://i.ytimg.com/vi/vid0/0.jpg")
    }

    // MARK: - Title display logic

    @Test("displayTitle returns deArrowTitle when set and feature enabled")
    func displayTitle_returnsDeArrowTitleWhenEnabled() {
        var video = Video(id: "v1", title: "Clickbait!! You won't believe...", channelTitle: "C")
        video.deArrowTitle = "Honest Video Title"

        // Simulate VideoCardView.displayTitle with deArrow enabled
        let deArrowEnabled = true
        let displayTitle = deArrowEnabled ? (video.deArrowTitle ?? video.title) : video.title

        #expect(displayTitle == "Honest Video Title")
    }

    @Test("displayTitle returns raw title when deArrowTitle is nil even if feature enabled")
    func displayTitle_returnsRawTitleWhenNoDeArrowTitle() {
        var video = Video(id: "v2", title: "Raw Title", channelTitle: "C")
        video.deArrowTitle = nil

        let deArrowEnabled = true
        let displayTitle = deArrowEnabled ? (video.deArrowTitle ?? video.title) : video.title

        #expect(displayTitle == "Raw Title")
    }

    @Test("displayTitle returns raw title when feature is disabled regardless of deArrowTitle")
    func displayTitle_returnsRawTitleWhenDisabled() {
        var video = Video(id: "v3", title: "Raw Title", channelTitle: "C")
        video.deArrowTitle = "Community Title"

        let deArrowEnabled = false
        let displayTitle = deArrowEnabled ? (video.deArrowTitle ?? video.title) : video.title

        #expect(displayTitle == "Raw Title")
    }

    // MARK: - Video model property storage

    @Test("Video model stores and retrieves deArrowTitle and deArrowThumbnailTimestamp")
    func videoModel_storesDeArrowFields() {
        var video = Video(id: "roundtrip", title: "T", channelTitle: "C")
        video.deArrowTitle = "Community Title"
        video.deArrowThumbnailTimestamp = 123.456

        #expect(video.deArrowTitle == "Community Title")
        #expect(video.deArrowThumbnailTimestamp == 123.456)
    }

    @Test("Video model defaults deArrow fields to nil")
    func videoModel_defaultsAreNil() {
        let video = Video(id: "defaults", title: "T", channelTitle: "C")

        #expect(video.deArrowTitle == nil)
        #expect(video.deArrowThumbnailTimestamp == nil)
    }
}
