import Foundation
import Testing
@testable import iPocketTubeCore

// MARK: - PoTokenInjectionTests
//
// Verifies that PlayerInfo.applyingPoToken(_:) correctly appends &pot= to all stream URLs,
// and that the injection is a no-op when no token is available.

@Suite("poToken Injection")
struct PoTokenInjectionTests {

    // MARK: - Helpers

    private func makeInfo(hlsURL: URL?, dashURL: URL?, formatURLs: [URL?]) -> PlayerInfo {
        let formats = formatURLs.enumerated().map { i, url in
            VideoFormat(label: "720p", width: 1280, height: 720, fps: 30, mimeType: "video/mp4", url: url)
        }
        return PlayerInfo(
            video: Video(id: "test", title: "Test", channelTitle: "Ch", thumbnailURL: nil),
            formats: formats,
            hlsURL: hlsURL,
            dashURL: dashURL,
            captionTracks: [],
            trackingURLs: nil,
            endCards: []
        )
    }

    // MARK: - applyingPoToken

    @Test("applyingPoToken appends pot= to hlsURL")
    func appendsToHLSURL() {
        let base = URL(string: "https://manifest.googlevideo.com/api/manifest/hls_playlist?expire=123")!
        let info = makeInfo(hlsURL: base, dashURL: nil, formatURLs: [])
        let patched = info.applyingPoToken("mytoken")
        #expect(patched.hlsURL?.absoluteString.contains("&pot=mytoken") == true)
    }

    @Test("applyingPoToken appends pot= to dashURL")
    func appendsToDashURL() {
        let base = URL(string: "https://manifest.googlevideo.com/api/manifest/dash?expire=123")!
        let info = makeInfo(hlsURL: nil, dashURL: base, formatURLs: [])
        let patched = info.applyingPoToken("dashtoken")
        #expect(patched.dashURL?.absoluteString.contains("&pot=dashtoken") == true)
    }

    @Test("applyingPoToken appends pot= to all non-nil format URLs")
    func appendsToFormatURLs() {
        let url1 = URL(string: "https://rr1.googlevideo.com/videoplayback?itag=18")!
        let url2 = URL(string: "https://rr2.googlevideo.com/videoplayback?itag=22")!
        let info = makeInfo(hlsURL: nil, dashURL: nil, formatURLs: [url1, url2, nil])
        let patched = info.applyingPoToken("tok")
        #expect(patched.formats[0].url?.absoluteString.contains("&pot=tok") == true)
        #expect(patched.formats[1].url?.absoluteString.contains("&pot=tok") == true)
        #expect(patched.formats[2].url == nil)
    }

    @Test("applyingPoToken does not duplicate separator for URL without query")
    func usesQuestionMarkForURLWithoutQuery() {
        let base = URL(string: "https://rr1.googlevideo.com/videoplayback")!
        let info = makeInfo(hlsURL: base, dashURL: nil, formatURLs: [])
        let patched = info.applyingPoToken("tok")
        #expect(patched.hlsURL?.absoluteString == "https://rr1.googlevideo.com/videoplayback?pot=tok")
    }

    @Test("applyingPoToken preserves nil hlsURL and dashURL")
    func preservesNilURLs() {
        let info = makeInfo(hlsURL: nil, dashURL: nil, formatURLs: [nil])
        let patched = info.applyingPoToken("tok")
        #expect(patched.hlsURL == nil)
        #expect(patched.dashURL == nil)
        #expect(patched.formats[0].url == nil)
    }

    @Test("applyingPoToken preserves other PlayerInfo fields")
    func preservesOtherFields() {
        let hls = URL(string: "https://example.com/hls?x=1")!
        let info = makeInfo(hlsURL: hls, dashURL: nil, formatURLs: [])
        let patched = info.applyingPoToken("tok")
        #expect(patched.video.id == info.video.id)
        #expect(patched.captionTracks.count == info.captionTracks.count)
        #expect(patched.trackingURLs == nil)
        #expect(patched.endCards.isEmpty)
    }
}
