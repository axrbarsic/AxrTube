import AVFoundation
import Foundation
import Testing
@testable import SmartTubeIOS
@testable import SmartTubeIOSCore

@Suite("Offline audio format fallback")
struct OfflineAudioFallbackTests {
    private actor AttemptCounter {
        private var value = 0

        func next() -> Int {
            value += 1
            return value
        }

        func current() -> Int { value }
    }

    private func format(
        _ mimeType: String,
        bitrate: Int,
        urlMarker: String? = "available"
    ) -> VideoFormat {
        VideoFormat(
            label: "fixture",
            width: mimeType.hasPrefix("video/") ? 640 : 0,
            height: mimeType.hasPrefix("video/") ? 360 : 0,
            fps: mimeType.hasPrefix("video/") ? 30 : 0,
            mimeType: mimeType,
            url: urlMarker.map { URL(string: "https://example.invalid/\($0)")! },
            bitrate: bitrate
        )
    }

    @Test("Selection prefers the highest-bitrate direct AAC/M4A stream")
    func selectsDirectM4AFirst() {
        let formats = [
            format("video/mp4; codecs=\"avc1.42001E, mp4a.40.2\"", bitrate: 300_000),
            format("audio/webm; codecs=\"opus\"", bitrate: 160_000),
            format("audio/mp4; codecs=\"mp4a.40.5\"", bitrate: 48_000),
            format("audio/mp4; codecs=\"mp4a.40.2\"", bitrate: 128_000),
        ]

        let plan = OfflineAudioFormatSelector.select(from: formats)
        #expect(plan?.source == .directM4A)
        #expect(plan?.format.bitrate == 128_000)
        #expect(plan?.downloadFileExtension == "m4a")
    }

    @Test("Selection accepts another AVFoundation-native audio container before video extraction")
    func selectsOtherNativeAudioSecond() {
        let formats = [
            format("video/mp4; codecs=\"avc1.42001E, mp4a.40.2\"", bitrate: 300_000),
            format("audio/webm; codecs=\"opus\"", bitrate: 160_000),
            format("audio/mpeg", bitrate: 96_000),
        ]

        let plan = OfflineAudioFormatSelector.select(from: formats)
        #expect(plan?.source == .directNativeAudio)
        #expect(plan?.downloadFileExtension == "mp3")
    }

    @Test("Missing adaptive URLs fall back to the compatible muxed MP4")
    func selectsMuxedMP4WhenAdaptiveURLsAreUnavailable() {
        let formats = [
            format("audio/mp4; codecs=\"mp4a.40.2\"", bitrate: 128_000, urlMarker: nil),
            format("audio/webm; codecs=\"opus\"", bitrate: 140_000, urlMarker: nil),
            format("video/mp4; codecs=\"avc1.42001E, mp4a.40.2\"", bitrate: 297_000),
        ]

        let plan = OfflineAudioFormatSelector.select(from: formats)
        #expect(plan?.source == .muxedMP4Extraction)
        #expect(plan?.downloadFileExtension == "mp4")
    }

    @Test("Every retry invokes the resolver and receives a fresh stream URL")
    func retryResolvesFreshFormats() async throws {
        let counter = AttemptCounter()
        func resolve() async throws -> OfflineAudioResolution {
            try await OfflineAudioFormatSelector.resolve {
                let resolutionCount = await counter.next()
                return [format(
                    "audio/mp4; codecs=\"mp4a.40.2\"",
                    bitrate: 128_000,
                    urlMarker: "attempt-\(resolutionCount)"
                )]
            }
        }

        let first = try await resolve()
        let second = try await resolve()

        #expect(await counter.current() == 2)
        #expect(first.plan?.format.url != second.plan?.format.url)
        #expect(second.plan?.source == .directM4A)
    }

    @Test("AVFoundation extracts an audio track from an MP4 container into playable M4A")
    func extractsMP4AudioToM4A() async throws {
        let source = try await makeMP4AudioFixture()
        defer { try? FileManager.default.removeItem(at: source) }

        let output = try await VideoDownloadService.extractAudioToM4A(
            inputURL: source,
            videoId: "offline-audio-fixture"
        )
        defer { try? FileManager.default.removeItem(at: output) }

        #expect(output.pathExtension == "m4a")
        #expect(FileManager.default.fileExists(atPath: output.path))
        let tracks = try await AVURLAsset(url: output).loadTracks(withMediaType: .audio)
        #expect(!tracks.isEmpty)
    }

    private func makeMP4AudioFixture() async throws -> URL {
        let systemSound = URL(fileURLWithPath: "/System/Library/Sounds/Glass.aiff")
        guard FileManager.default.fileExists(atPath: systemSound.path) else {
            throw CocoaError(.fileNoSuchFile)
        }

        let asset = AVURLAsset(url: systemSound)
        let m4aURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-fixture.m4a")
        let mp4URL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-fixture.mp4")
        defer { try? FileManager.default.removeItem(at: m4aURL) }

        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw CocoaError(.featureUnsupported)
        }
        exporter.outputURL = m4aURL
        exporter.outputFileType = .m4a
        await exporter.export()
        if let error = exporter.error { throw error }

        // M4A is an ISO base media container. Renaming the fixture to `.mp4`
        // exercises the production container-to-M4A extraction path without a
        // checked-in binary fixture or an external encoder.
        try FileManager.default.copyItem(at: m4aURL, to: mp4URL)
        return mp4URL
    }
}
