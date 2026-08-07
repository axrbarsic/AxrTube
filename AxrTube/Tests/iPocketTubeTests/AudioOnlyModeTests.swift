import Foundation
import Testing
@testable import iPocketTubeCore

// MARK: - AudioOnlyModeTests
//
// Verifies the data-layer behaviour underpinning audio-only playback:
//   1. AppSettings.audioOnlyMode is persisted with the correct default.
//   2. PlayerInfo.bestAdaptiveAudioURL returns the highest-bitrate audio/mp4 URL.
//   3. bestAdaptiveAudioURL returns nil when no audio/mp4 formats are present.
//   4. isLive guard: live videos have no adaptive audio URL to try (no format added).
//   5. Offline resolver identities and fallback order stay current.

@Suite("Audio-Only Mode")
struct AudioOnlyModeTests {

    // MARK: - Helpers

    private func makeVideo(id: String = "abc", isLive: Bool = false) -> Video {
        Video(id: id, title: "Test", channelTitle: "Ch", thumbnailURL: nil, isLive: isLive)
    }

    private func makeInfo(
        formats: [VideoFormat],
        isLive: Bool = false
    ) -> PlayerInfo {
        PlayerInfo(
            video: makeVideo(isLive: isLive),
            formats: formats,
            hlsURL: URL(string: "https://example.com/hls.m3u8"),
            dashURL: nil,
            captionTracks: [],
            trackingURLs: nil,
            endCards: []
        )
    }

    private func audioFormat(bitrate: Int, url: String) -> VideoFormat {
        VideoFormat(
            label: "audio",
            width: 0,
            height: 0,
            fps: 0,
            mimeType: "audio/mp4; codecs=\"mp4a.40.2\"",
            url: URL(string: url)!,
            bitrate: bitrate
        )
    }

    private func videoFormat(bitrate: Int) -> VideoFormat {
        VideoFormat(
            label: "720p",
            width: 1280,
            height: 720,
            fps: 30,
            mimeType: "video/mp4; codecs=\"avc1.42001E\"",
            url: URL(string: "https://example.com/video.mp4")!,
            bitrate: bitrate
        )
    }

    // MARK: - AppSettings.audioOnlyMode default

    @Test("audioOnlyMode defaults to false")
    func audioOnlyModeDefault() {
        let settings = AppSettings()
        #expect(settings.audioOnlyMode == false)
    }

    @Test("audioOnlyMode can be enabled")
    func audioOnlyModeEnabled() {
        var settings = AppSettings()
        settings.audioOnlyMode = true
        #expect(settings.audioOnlyMode == true)
    }

    // MARK: - PlayerInfo.bestAdaptiveAudioURL

    @Test("bestAdaptiveAudioURL returns URL when audio/mp4 format present")
    func bestAdaptiveAudioURL_withAudioFormat() {
        let fmt = audioFormat(bitrate: 128000, url: "https://audio.example.com/128k.mp4")
        let info = makeInfo(formats: [fmt])
        #expect(info.bestAdaptiveAudioURL == URL(string: "https://audio.example.com/128k.mp4"))
    }

    @Test("bestAdaptiveAudioURL returns nil when no audio/mp4 formats present")
    func bestAdaptiveAudioURL_noAudioFormat() {
        let fmt = videoFormat(bitrate: 3_000_000)
        let info = makeInfo(formats: [fmt])
        #expect(info.bestAdaptiveAudioURL == nil)
    }

    @Test("bestAdaptiveAudioURL picks highest bitrate when multiple audio formats")
    func bestAdaptiveAudioURL_highestBitrate() {
        let low  = audioFormat(bitrate: 64_000,  url: "https://audio.example.com/64k.mp4")
        let high = audioFormat(bitrate: 256_000, url: "https://audio.example.com/256k.mp4")
        let mid  = audioFormat(bitrate: 128_000, url: "https://audio.example.com/128k.mp4")
        let info = makeInfo(formats: [low, high, mid])
        #expect(info.bestAdaptiveAudioURL == URL(string: "https://audio.example.com/256k.mp4"))
    }

    @Test("bestAdaptiveAudioURL returns nil for format with nil url")
    func bestAdaptiveAudioURL_nilURL() {
        let fmt = VideoFormat(
            label: "audio",
            width: 0, height: 0, fps: 0,
            mimeType: "audio/mp4; codecs=\"mp4a.40.2\"",
            url: nil,
            bitrate: 128_000
        )
        let info = makeInfo(formats: [fmt])
        #expect(info.bestAdaptiveAudioURL == nil)
    }

    // MARK: - InnerTubeClients.AndroidVR

    @Test("AndroidVR client name is ANDROID_VR")
    func androidVRClientName() {
        #expect(InnerTubeClients.AndroidVR.name == "ANDROID_VR")
    }

    @Test("AndroidVR nameID is 28")
    func androidVRNameID() {
        #expect(InnerTubeClients.AndroidVR.nameID == "28")
    }

    @Test("AndroidVR userAgent contains version and platform")
    func androidVRUserAgent() {
        let ua = InnerTubeClients.AndroidVR.userAgent
        #expect(ua.contains("com.google.android.apps.youtube.vr.oculus"))
        #expect(ua.contains(InnerTubeClients.AndroidVR.version))
        #expect(ua.contains("Android 12"))
    }

    @Test("VisionOS client identity matches the JS-less player profile")
    func visionOSClientIdentity() {
        #expect(InnerTubeClients.VisionOS.name == "VISIONOS")
        #expect(InnerTubeClients.VisionOS.nameID == "101")
        #expect(InnerTubeClients.VisionOS.version == "1.02")
        #expect(InnerTubeClients.VisionOS.userAgent.contains("Version/26.0"))
        #expect(InnerTubeClients.VisionOS.osName == "visionOS")
    }

    @Test("Offline audio resolver prefers VisionOS and keeps independent fallbacks")
    func resolverPreferenceOrder() {
        #expect(OfflineAudioResolverClient.preferredOrder == [
            .visionOS,
            .androidVR,
            .android,
        ])
        #expect(Set(OfflineAudioResolverClient.preferredOrder.map(\.userAgent)).count == 3)
    }

    @Test("Android fallback identity uses the maintained client version")
    func androidClientVersionIsCurrent() {
        #expect(InnerTubeClients.Android.version == "21.26.364")
        #expect(InnerTubeClients.Android.userAgent.contains("21.26.364"))
    }
}
