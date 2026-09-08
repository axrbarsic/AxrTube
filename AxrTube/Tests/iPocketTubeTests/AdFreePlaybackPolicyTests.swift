import Foundation
import Testing
@testable import iPocketTubeCore
#if canImport(WebKit)
import WebKit
@testable import iPocketTube
#endif

@Suite("Ad-free playback boundaries")
struct AdFreePlaybackPolicyTests {
    @Test func onlyVerifiedMainContentManifestIsAccepted() {
        let url = URL(string: "https://manifest.googlevideo.com/api/manifest/hls/id/content")!
        #expect(AdFreePlaybackPolicy.acceptsManifest(url: url, source: "apiResponse",
            requestedVideoID: "main", pageVideoID: "main", contentVideoID: "main"))
        for source in ["videoSrc", "xhrManifest", "fetchManifest", "unknown"] {
            #expect(!AdFreePlaybackPolicy.acceptsManifest(url: url, source: source,
                requestedVideoID: "main", pageVideoID: "main", contentVideoID: "main"))
        }
        for contentID in [nil, "advertisement", "previous-video"] as [String?] {
            #expect(!AdFreePlaybackPolicy.acceptsManifest(url: url, source: "apiResponse",
                requestedVideoID: "main", pageVideoID: "main", contentVideoID: contentID))
        }
        for host in ["https://googlevideo.com.attacker.test/manifest", "http://manifest.googlevideo.com/hls"] {
            #expect(!AdFreePlaybackPolicy.acceptsManifest(url: URL(string: host)!, source: "apiResponse",
                requestedVideoID: "main", pageVideoID: "main", contentVideoID: "main"))
        }
    }

    #if canImport(WebKit)
    @Test @MainActor func hiddenResolverCannotAutoplayOrBecomePictureInPicture() {
        let configuration = WKWebViewConfiguration()
        ResolverWebViewPolicy.configure(configuration)
        #expect(configuration.mediaTypesRequiringUserActionForPlayback == .all)
        #if os(iOS)
        #expect(!configuration.allowsPictureInPictureMediaPlayback)
        #endif
    }
    #endif
}
