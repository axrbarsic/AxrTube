import Foundation
import Testing
@testable import iPocketTubeCore

// MARK: - TVClientHLSNilFallbackTests (NW-3-FIX)
//
// Verifies the model-level condition that guards the NW-3-FIX fallback in
// PlaybackViewModel+Loading.swift.
//
// When the TV authenticated client returns a `PlayerInfo` with:
//   - hlsURL = nil
//   - bestAdaptiveVideoURL = nil  (no video-only adaptive stream)
//   - bestAdaptiveAudioURL = nil  (no audio-only adaptive stream)
//
// …the fallback condition fires and the Android client is used instead, avoiding
// an AVFoundationErrorDomain -11828 / NSOSStatusErrorDomain -12847 failure.
//
// The fix lives in PlaybackViewModel+Loading.swift:
//   if info.hlsURL == nil,
//      info.bestAdaptiveVideoURL == nil || info.bestAdaptiveAudioURL == nil { … }
//
// These tests validate the three `PlayerInfo` computed properties that feed that
// condition, for the two key TV-client response shapes.

@Suite("NW-3-FIX: TV client HLS-nil fallback condition")
struct TVClientHLSNilFallbackTests {

    // MARK: - Helpers

    private func makeVideo() -> Video {
        Video(id: "test-video", title: "Test", channelTitle: "Channel")
    }

    /// A `PlayerInfo` shaped like a TV-client response for DRM/protected content:
    /// only a muxed MP4 (itag=18, two codecs), no HLS, no adaptive streams.
    private func makeMuxedOnlyPlayerInfo() -> PlayerInfo {
        let muxedFormat = VideoFormat(
            label: "360p",
            width: 640, height: 360, fps: 30,
            mimeType: "video/mp4; codecs=\"avc1.42001E, mp4a.40.2\"",
            url: URL(string: "https://r1---sn-foo.googlevideo.com/videoplayback?itag=18"),
            bitrate: 500_000
        )
        return PlayerInfo(
            video: makeVideo(),
            formats: [muxedFormat],
            hlsURL: nil,
            dashURL: nil,
            captionTracks: [],
            trackingURLs: nil,
            endCards: []
        )
    }

    /// A `PlayerInfo` with a valid HLS URL (normal TV or iOS client response).
    private func makeHLSPlayerInfo() -> PlayerInfo {
        PlayerInfo(
            video: makeVideo(),
            formats: [],
            hlsURL: URL(string: "https://manifest.googlevideo.com/api/manifest/hls_playlist"),
            dashURL: nil,
            captionTracks: [],
            trackingURLs: nil,
            endCards: []
        )
    }

    /// A `PlayerInfo` with adaptive video + audio streams but no HLS (Android-client shape).
    private func makeAdaptivePlayerInfo() -> PlayerInfo {
        let videoFormat = VideoFormat(
            label: "1080p",
            width: 1920, height: 1080, fps: 30,
            mimeType: "video/mp4; codecs=\"avc1.640028\"",
            url: URL(string: "https://r1---sn-foo.googlevideo.com/videoplayback?itag=137"),
            bitrate: 3_000_000
        )
        let audioFormat = VideoFormat(
            label: "Audio",
            width: 0, height: 0, fps: 0,
            mimeType: "audio/mp4; codecs=\"mp4a.40.2\"",
            url: URL(string: "https://r1---sn-foo.googlevideo.com/videoplayback?itag=140"),
            bitrate: 128_000
        )
        return PlayerInfo(
            video: makeVideo(),
            formats: [videoFormat, audioFormat],
            hlsURL: nil,
            dashURL: nil,
            captionTracks: [],
            trackingURLs: nil,
            endCards: []
        )
    }

    // MARK: - Muxed-only (TV client DRM response)

    @Test("Muxed-only TV response: hlsURL is nil")
    func muxedOnlyHlsURLIsNil() {
        let info = makeMuxedOnlyPlayerInfo()
        #expect(info.hlsURL == nil)
    }

    @Test("Muxed-only TV response: bestAdaptiveVideoURL is nil (muxed codec string excluded)")
    func muxedOnlyAdaptiveVideoURLIsNil() {
        let info = makeMuxedOnlyPlayerInfo()
        // Muxed formats have two codecs separated by ", " — the filter in
        // bestAdaptiveVideoURL requires !mimeType.contains(", ") so it is excluded.
        #expect(info.bestAdaptiveVideoURL == nil)
    }

    @Test("Muxed-only TV response: bestAdaptiveAudioURL is nil")
    func muxedOnlyAdaptiveAudioURLIsNil() {
        let info = makeMuxedOnlyPlayerInfo()
        #expect(info.bestAdaptiveAudioURL == nil)
    }

    @Test("Muxed-only TV response: NW-3-FIX fallback condition fires")
    func muxedOnlyFallbackConditionFires() {
        let info = makeMuxedOnlyPlayerInfo()
        let shouldFallback = info.hlsURL == nil &&
            (info.bestAdaptiveVideoURL == nil || info.bestAdaptiveAudioURL == nil)
        #expect(shouldFallback,
                "Expected NW-3-FIX condition to be true for muxed-only TV response")
    }

    // MARK: - HLS response (no fallback expected)

    @Test("HLS response: fallback condition does NOT fire")
    func hlsResponseFallbackConditionDoesNotFire() {
        let info = makeHLSPlayerInfo()
        let shouldFallback = info.hlsURL == nil &&
            (info.bestAdaptiveVideoURL == nil || info.bestAdaptiveAudioURL == nil)
        #expect(!shouldFallback,
                "NW-3-FIX condition must not fire when hlsURL is present")
    }

    // MARK: - Adaptive streams response (no fallback expected)

    @Test("Adaptive-only response: bestAdaptiveVideoURL is non-nil")
    func adaptiveResponseHasVideoURL() {
        let info = makeAdaptivePlayerInfo()
        #expect(info.bestAdaptiveVideoURL != nil)
    }

    @Test("Adaptive-only response: bestAdaptiveAudioURL is non-nil")
    func adaptiveResponseHasAudioURL() {
        let info = makeAdaptivePlayerInfo()
        #expect(info.bestAdaptiveAudioURL != nil)
    }

    @Test("Adaptive-only response: fallback condition does NOT fire")
    func adaptiveResponseFallbackConditionDoesNotFire() {
        let info = makeAdaptivePlayerInfo()
        // hlsURL is nil BUT both adaptive streams are present — only one nil needed
        // for the condition to fire, so we also need hlsURL == nil to be true here.
        // The full condition is: hlsURL==nil AND (adaptiveVideo==nil OR adaptiveAudio==nil)
        // With adaptive streams present both are non-nil, so the AND's RHS is false.
        let shouldFallback = info.hlsURL == nil &&
            (info.bestAdaptiveVideoURL == nil || info.bestAdaptiveAudioURL == nil)
        #expect(!shouldFallback,
                "NW-3-FIX condition must not fire when adaptive streams are available")
    }

    // MARK: - NW-3-FIX (extended): Android muxed-only response

    /// Mirrors `retryWithFallbackPlayer`'s new NW-3-FIX-ANDROID guard:
    ///   if fallbackInfo.hlsURL == nil,
    ///      fallbackInfo.bestAdaptiveVideoURL == nil,
    ///      fallbackInfo.bestAdaptiveAudioURL == nil { … }
    private func shouldSkipAndroidMuxedFallback(_ info: PlayerInfo) -> Bool {
        info.hlsURL == nil &&
        info.bestAdaptiveVideoURL == nil &&
        info.bestAdaptiveAudioURL == nil
    }

    @Test("NW-3-FIX-ANDROID: muxed-only Android response triggers early-exit guard")
    func androidMuxedOnlyTriggersEarlyExit() {
        let info = makeMuxedOnlyPlayerInfo()
        // Same muxed-only shape applies whether from TV or Android client.
        #expect(shouldSkipAndroidMuxedFallback(info),
                "Guard must fire for muxed-only Android response to prevent AVFoundation -11828 non-fatal")
    }

    @Test("NW-3-FIX-ANDROID: HLS Android response does NOT trigger early-exit guard")
    func androidHLSResponseDoesNotTriggerEarlyExit() {
        let info = makeHLSPlayerInfo()
        #expect(!shouldSkipAndroidMuxedFallback(info),
                "Guard must not fire when Android returns HLS")
    }

    @Test("NW-3-FIX-ANDROID: adaptive Android response does NOT trigger early-exit guard")
    func androidAdaptiveResponseDoesNotTriggerEarlyExit() {
        let info = makeAdaptivePlayerInfo()
        #expect(!shouldSkipAndroidMuxedFallback(info),
                "Guard must not fire when Android returns adaptive streams")
    }

    @Test("NW-3-FIX-ANDROID: muxed-only response still has a preferredStreamURL (muxed URL)")
    func androidMuxedOnlyHasPreferredStreamURL() {
        // Confirms the guard is necessary — preferredStreamURL returns a non-nil muxed URL
        // even in this case, so without the guard AVPlayer would be tried and fail.
        let info = makeMuxedOnlyPlayerInfo()
        #expect(info.preferredStreamURL != nil,
                "muxed-only response has a preferredStreamURL — guard prevents handing it to AVPlayer")
        #expect(shouldSkipAndroidMuxedFallback(info),
                "Guard must fire so we don't pass the muxed URL to AVPlayer")
    }

    // MARK: - Fix #122: Android no-HLS with adaptive streams → use adaptive composition

    /// The new guard in retryWithFallbackPlayer (Fix #122):
    ///   if fallbackInfo.hlsURL == nil,
    ///      fallbackInfo.bestAdaptiveVideoURL != nil,
    ///      fallbackInfo.bestAdaptiveAudioURL != nil { → use adaptive composition }
    private func shouldDelegateToAdaptiveComposition(_ info: PlayerInfo) -> Bool {
        info.hlsURL == nil &&
        info.bestAdaptiveVideoURL != nil &&
        info.bestAdaptiveAudioURL != nil
    }

    @Test("Fix #122: Android adaptive-only response triggers adaptive composition delegation")
    func fix122AdaptiveOnlyTriggersDelegation() {
        // Adaptive video + audio, no HLS — the new guard must route to adaptive composition
        // instead of using preferredStreamURL (muxed URL) which would fail with -11828.
        let info = makeAdaptivePlayerInfo()
        #expect(shouldDelegateToAdaptiveComposition(info),
                "Fix #122: guard must fire for no-HLS + adaptive Android response")
    }

    @Test("Fix #122: adaptive response preferredStreamURL returns nil (no muxed URL to fall back to)")
    func fix122AdaptiveOnlyPreferredStreamURLIsNil() {
        // When the Android response has only adaptive streams (no muxed MP4 with ", "),
        // preferredStreamURL returns nil — confirming the muxed path cannot be used.
        let info = makeAdaptivePlayerInfo()
        #expect(info.preferredStreamURL == nil,
                "Fix #122: adaptive-only response has no muxed URL — must use adaptive composition")
    }

    @Test("Fix #122: HLS Android response does NOT trigger adaptive composition delegation")
    func fix122HLSResponseDoesNotTriggerDelegation() {
        let info = makeHLSPlayerInfo()
        #expect(!shouldDelegateToAdaptiveComposition(info),
                "Fix #122: delegation must not fire when Android returns HLS")
    }

    @Test("Fix #122: muxed-only Android response does NOT trigger adaptive composition (caught by earlier guard)")
    func fix122MuxedOnlyDoesNotTriggerDelegation() {
        // Muxed-only has no adaptive streams, so the Fix #122 condition is false.
        // The earlier NW-3-FIX guard catches it first.
        let info = makeMuxedOnlyPlayerInfo()
        #expect(!shouldDelegateToAdaptiveComposition(info),
                "Fix #122: delegation must not fire for muxed-only — NW-3-FIX guard handles it")
    }
}
