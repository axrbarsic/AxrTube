import Foundation
import Testing
@testable import iPocketTubeCore

// MARK: - SABRDetectionTests
//
// Regression tests for #204: PlayerInfo.containsSabrFormats detects SABR-only
// adaptive streams (c=TVHTML5 URLs) so PlaybackViewModel can skip the 60-second
// AVURLAsset.loadTracks stall and route directly to WKWebView HLS.

@Suite("SABR Detection")
struct SABRDetectionTests {

    // MARK: - Helpers

    private func makeFormat(mimeType: String, urlString: String?) -> VideoFormat {
        VideoFormat(
            label: "test",
            width: 1280, height: 720, fps: 30,
            mimeType: mimeType,
            url: urlString.flatMap { URL(string: $0) }
        )
    }

    private func makePlayerInfo(formats: [VideoFormat]) -> PlayerInfo {
        PlayerInfo(
            video: Video(id: "test", title: "Test", channelTitle: "Channel"),
            formats: formats,
            hlsURL: nil,
            dashURL: nil,
            captionTracks: [],
            trackingURLs: nil,
            endCards: []
        )
    }

    private let sabrURL = "https://rr1.googlevideo.com/videoplayback?itag=137&c=TVHTML5&source=yt"
    private let normalURL = "https://rr1.googlevideo.com/videoplayback?itag=137&c=IOS&source=yt"

    // MARK: - Tests

    @Test func containsSabrFormats_allSabrAdaptive_returnsTrue() {
        let formats = [
            makeFormat(mimeType: "video/mp4; codecs=\"avc1.640028\"", urlString: sabrURL),
            makeFormat(mimeType: "video/mp4; codecs=\"avc1.4d401f\"", urlString: sabrURL),
        ]
        let info = makePlayerInfo(formats: formats)
        #expect(info.containsSabrFormats == true)
    }

    @Test func containsSabrFormats_mixedSabrAndNormal_returnsFalse() {
        let formats = [
            makeFormat(mimeType: "video/mp4; codecs=\"avc1.640028\"", urlString: sabrURL),
            makeFormat(mimeType: "video/mp4; codecs=\"avc1.4d401f\"", urlString: normalURL),
        ]
        let info = makePlayerInfo(formats: formats)
        #expect(info.containsSabrFormats == false)
    }

    @Test func containsSabrFormats_noAdaptiveFormats_returnsFalse() {
        let info = makePlayerInfo(formats: [])
        #expect(info.containsSabrFormats == false)
    }

    @Test func containsSabrFormats_muxedFormatOnly_returnsFalse() {
        // Muxed formats have ", " in mimeType — excluded from adaptive check
        let formats = [
            makeFormat(mimeType: "video/mp4; codecs=\"avc1.42001E, mp4a.40.2\"", urlString: sabrURL),
        ]
        let info = makePlayerInfo(formats: formats)
        #expect(info.containsSabrFormats == false)
    }

    @Test func containsSabrFormats_normalAdaptiveURL_returnsFalse() {
        let formats = [
            makeFormat(mimeType: "video/mp4; codecs=\"avc1.640028\"", urlString: normalURL),
        ]
        let info = makePlayerInfo(formats: formats)
        #expect(info.containsSabrFormats == false)
    }

    @Test func containsSabrFormats_nilURL_returnsFalse() {
        // Formats with no URL are excluded from adaptive check
        let formats = [
            makeFormat(mimeType: "video/mp4; codecs=\"avc1.640028\"", urlString: nil),
        ]
        let info = makePlayerInfo(formats: formats)
        #expect(info.containsSabrFormats == false)
    }
}
