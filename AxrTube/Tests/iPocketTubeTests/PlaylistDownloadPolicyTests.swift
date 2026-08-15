import Foundation
import Testing
@testable import iPocketTubeCore

@Suite("Brave-style video playlist policy")
struct PlaylistDownloadPolicyTests {
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
}
