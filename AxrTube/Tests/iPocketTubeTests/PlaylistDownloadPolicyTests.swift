import Foundation
import Testing
@testable import iPocketTubeCore

@Suite("Brave-style video playlist policy")
struct PlaylistDownloadPolicyTests {
    @Test("Offline transfer yields during startup and stalls, not steady playback")
    func playbackHasPriority() {
        #expect(PlaylistDownloadPolicy.shouldYieldToPlayback(preparing: true, waitingForBuffer: false))
        #expect(PlaylistDownloadPolicy.shouldYieldToPlayback(preparing: false, waitingForBuffer: true))
        #expect(!PlaylistDownloadPolicy.shouldYieldToPlayback(preparing: false, waitingForBuffer: false))
    }

    @Test("HLS is preferred over a muxed file")
    func hlsFirst() throws {
        let hls = try #require(URL(string: "https://example.com/master.m3u8"))
        let file = try #require(URL(string: "https://example.com/video.mp4"))
        #expect(PlaylistDownloadPolicy.source(hlsURL: hls, muxedFileURL: file) == .hls(hls))
    }

    @Test("Muxed video is the fallback")
    func fileFallback() throws {
        let file = try #require(URL(string: "https://example.com/video.mp4"))
        #expect(PlaylistDownloadPolicy.source(hlsURL: nil, muxedFileURL: file) == .file(file))
        #expect(PlaylistDownloadPolicy.source(hlsURL: nil, muxedFileURL: nil) == nil)
    }

    @Test("Background task identity survives relaunch")
    func taskIdentityRoundTrip() {
        let original = PlaylistTaskIdentity(kind: .hls, videoID: "QVijqSx9bts")
        #expect(PlaylistTaskIdentity(taskDescription: original.taskDescription) == original)
        #expect(PlaylistTaskIdentity(taskDescription: "broken") == nil)
    }

    @Test("Direct file request matches Brave Playlist headers")
    func braveFileRequestHeaders() throws {
        let url = try #require(URL(string: "https://example.com/video.mp4"))
        let request = PlaylistDownloadPolicy.fileRequest(
            url: url,
            userAgent: "AxrTube-Test",
            playbackSessionID: "session-123"
        )
        #expect(request.value(forHTTPHeaderField: "Range") == "bytes=0-")
        #expect(request.value(forHTTPHeaderField: "X-Playback-Session-Id") == "session-123")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "AxrTube-Test")
        #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
        #expect(request.timeoutInterval == 60)
    }

    @Test("Brave-compatible HTTP status policy")
    func acceptedStatuses() {
        #expect(PlaylistDownloadPolicy.acceptsHTTPStatus(200))
        #expect(PlaylistDownloadPolicy.acceptsHTTPStatus(206))
        #expect(!PlaylistDownloadPolicy.acceptsHTTPStatus(302))
        #expect(!PlaylistDownloadPolicy.acceptsHTTPStatus(199))
        #expect(!PlaylistDownloadPolicy.acceptsHTTPStatus(404))
    }

    @Test("Background failures never expose raw NSError text")
    func userFacingFailureMessages() {
        let stale = PlaylistDownloadPolicy.failureMessage(
            urlErrorCode: NSURLErrorBadServerResponse,
            httpStatus: 403
        )
        let offline = PlaylistDownloadPolicy.failureMessage(
            urlErrorCode: NSURLErrorNotConnectedToInternet,
            httpStatus: nil
        )
        #expect(stale.contains("Повторить"))
        #expect(offline.contains("Повторить"))
        #expect(!stale.contains("NSURLErrorDomain"))
        #expect(!offline.contains("-1009"))
    }
}
