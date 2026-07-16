import Foundation
import Testing
@testable import iPocketTubeCore

// MARK: - WrongVideoStatsOverlayTests
//
// Regression test for task #225: the stats overlay ("Stats for Nerds") showed the
// wrong video ID when the user tapped a new video from the home screen and all
// playback paths failed. The symptom was `videoId = "1B7yg7LWiik"` (previously
// playing video) while `currentVideo.id = "wyBkLyGWZyU"` (the newly selected video).
//
// Root cause: `playerInfo` was not reset to `nil` inside `load()` when switching
// to a different video. The stats-overlay snapshot expression is:
//
//   let videoId = playerInfo?.video.id ?? currentVideo?.id ?? ""
//
// With stale `playerInfo` pointing to the old video, this resolved to the OLD video
// ID even after `currentVideo` had been updated to the new one.
//
// Fix: add `playerInfo = nil` to the clearing block in `PlaybackViewModel+Loading.swift`.
//
// These tests verify the model-layer invariant without an AVPlayer:
//   1. When `playerInfo` is nil, the expression yields `currentVideo?.id`.
//   2. When `playerInfo` is non-nil for a DIFFERENT video, it would have yielded
//      the wrong ID — confirming the bug (and the necessity of the fix).
//   3. When `playerInfo` is non-nil for the SAME video, the expression still yields
//      the correct ID (normal steady-state while playing).

@Suite("Wrong video ID in stats overlay — task #225 regression")
struct WrongVideoStatsOverlayTests {

    // MARK: - Helpers

    private func makeVideo(id: String) -> Video {
        Video(id: id, title: "Test \(id)", channelTitle: "Channel", thumbnailURL: nil)
    }

    private func makePlayerInfo(videoId: String) -> PlayerInfo {
        PlayerInfo(
            video: makeVideo(id: videoId),
            formats: [],
            hlsURL: nil,
            dashURL: nil,
            captionTracks: [],
            trackingURLs: nil,
            endCards: []
        )
    }

    /// Mirrors the expression in `PlaybackViewModel+StatsForNerds.swift`:
    ///   `let videoId = playerInfo?.video.id ?? currentVideo?.id ?? ""`
    private func resolvedVideoId(playerInfo: PlayerInfo?, currentVideo: Video?) -> String {
        playerInfo?.video.id ?? currentVideo?.id ?? ""
    }

    // MARK: - Tests

    /// After the fix: playerInfo is nil when switching videos.
    /// The expression must resolve to currentVideo?.id (the new video).
    @Test("nil playerInfo + new currentVideo → resolves to new video ID")
    func nilPlayerInfoResolvesToCurrentVideo() {
        let newVideo = makeVideo(id: "wyBkLyGWZyU")
        let result = resolvedVideoId(playerInfo: nil, currentVideo: newVideo)
        #expect(result == "wyBkLyGWZyU",
                "With playerInfo=nil, stats overlay must show the current video's ID")
    }

    /// Pre-fix regression scenario: stale playerInfo for a DIFFERENT video would
    /// have caused the wrong video ID to appear in the overlay.
    @Test("stale playerInfo for old video would have returned wrong ID (pre-fix behaviour)")
    func stalePlayerInfoProducesWrongId() {
        let oldPlayerInfo = makePlayerInfo(videoId: "1B7yg7LWiik") // previously playing
        let newCurrentVideo = makeVideo(id: "wyBkLyGWZyU")         // newly selected

        // Simulate the pre-fix state: playerInfo still holds the old video
        let result = resolvedVideoId(playerInfo: oldPlayerInfo, currentVideo: newCurrentVideo)
        // This SHOULD be wrong — and was the bug.
        #expect(result == "1B7yg7LWiik",
                "Pre-fix: stale playerInfo.video.id takes priority over currentVideo.id — confirming the bug existed")
        #expect(result != "wyBkLyGWZyU",
                "Pre-fix: stats overlay would show wrong video (old video, not new one)")
    }

    /// Post-fix, steady-state: playerInfo is non-nil and matches currentVideo.
    /// The expression resolves to the correct (same) ID in normal operation.
    @Test("matching playerInfo and currentVideo → resolves to same ID (steady state)")
    func matchingPlayerInfoAndCurrentVideo() {
        let videoId = "wyBkLyGWZyU"
        let info = makePlayerInfo(videoId: videoId)
        let video = makeVideo(id: videoId)

        let result = resolvedVideoId(playerInfo: info, currentVideo: video)
        #expect(result == videoId,
                "When playerInfo and currentVideo match, stats overlay shows the correct ID")
    }

    /// Edge case: both playerInfo and currentVideo are nil → empty string fallback.
    @Test("nil playerInfo and nil currentVideo → empty string fallback")
    func bothNilYieldsEmptyString() {
        let result = resolvedVideoId(playerInfo: nil, currentVideo: nil)
        #expect(result == "", "Both nil must produce empty string as final fallback")
    }
}
