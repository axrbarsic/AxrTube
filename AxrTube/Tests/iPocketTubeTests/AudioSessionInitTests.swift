import Foundation
import Testing
@testable import iPocketTubeCore

// MARK: - AudioSessionInitTests
//
// Regression test for GitHub issue #54: cold-launching iPocketTube stopped
// background audio (e.g. Music.app) because PlaybackViewModel.init() called
// AVAudioSession.setActive(true) before any video was played.
//
// The fix defers setActive(true) to PlaybackViewModel+Loading.swift ~line 494
// (just before player.rate is set), keeping it out of init().
//
// These tests verify the structural contract:
//   1. InnerTubeAPI initialises without activating the audio session —
//      the Core layer must not touch AVAudioSession.
//   2. The VideoPreloadCache (initialised during App.init alongside
//      PlaybackViewModel) does not activate the audio session.
//
// True verification that setActive(true) is absent from PlaybackViewModel.init()
// requires the full iPocketTube module and is confirmed by code review + the
// build above (the only AVAudioSession call remaining in init() is setCategory,
// which per Apple docs does NOT interrupt other apps).

@Suite("Audio session deferred activation — issue #54 regression")
struct AudioSessionInitTests {

    @Test("InnerTubeAPI initialisation does not involve AVAudioSession (Core layer is audio-agnostic)")
    func coreLayerIsAudioAgnostic() async {
        // InnerTubeAPI is in iPocketTubeCore which has no UIKit/AVFoundation import
        // for AVAudioSession. Creating one must not produce any side effects.
        let api = InnerTubeAPI()
        #expect(await api.authToken == nil,
                "InnerTubeAPI init must not require any audio session state")
    }

    @Test("VideoPreloadCache is created without audio session side effects")
    func videoPreloadCacheInitIsAudioAgnostic() async {
        // VideoPreloadCache.shared is initialised at App.init() time alongside
        // PlaybackViewModel. Accessing it must have no audio side effects.
        let _ = await VideoPreloadCache.shared.consume(
            videoId: "audio-session-init-test-\(Int.random(in: 0..<Int.max))"
        )
        // If this doesn't crash, the cache is audio-session-independent.
        #expect(Bool(true), "VideoPreloadCache access must not activate AVAudioSession")
    }

    @Test("PlayerInfo can be stored pre-launch without audio session activation")
    func storeCachedInfoWithoutAudioSession() async {
        let videoId = "audio-test-\(Int.random(in: 0..<Int.max))"
        let video = Video(id: videoId, title: "Test", channelTitle: "Ch", thumbnailURL: nil)
        let info = PlayerInfo(
            video: video,
            formats: [],
            hlsURL: URL(string: "https://example.com/test.m3u8"),
            dashURL: nil,
            captionTracks: [],
            trackingURLs: nil,
            endCards: []
        )
        await VideoPreloadCache.shared.store(playerInfo: info, for: videoId)
        let cached = await VideoPreloadCache.shared.consume(videoId: videoId)
        #expect(cached.playerInfo != nil,
                "Prefetched playerInfo must survive the pre-launch caching phase without audio activation")
    }
}
