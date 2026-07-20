import Foundation

/// The ordered, system-native sources iPocketTube can use for an offline audio item.
/// URLs are deliberately never included in the diagnostic representation.
public enum OfflineAudioSourceKind: String, Sendable, Equatable {
    case directM4A
    case directNativeAudio
    case muxedMP4Extraction
}

public struct OfflineAudioDownloadPlan: Sendable, Equatable {
    public let source: OfflineAudioSourceKind
    public let format: VideoFormat
    public let downloadFileExtension: String

    public init(
        source: OfflineAudioSourceKind,
        format: VideoFormat,
        downloadFileExtension: String
    ) {
        self.source = source
        self.format = format
        self.downloadFileExtension = downloadFileExtension
    }
}

public struct OfflineAudioResolution: Sendable {
    public let formats: [VideoFormat]
    public let plan: OfflineAudioDownloadPlan?
}

/// Owned failure identity for format resolution. A missing compatible YouTube
/// representation is not an HTTP content-decoding failure and must never be
/// surfaced as NSURLErrorCannotDecodeContentData.
public enum AudioSourceResolutionFailure: Int, Sendable, Equatable {
    case unsupportedFormats = 1
    case selectedURLMissing = 2
    case unsupportedPlaybackPlan = 3

    public static let errorDomain = "iPocketTubeAudioResolution"

    public var diagnosticCode: String {
        switch self {
        case .unsupportedFormats: "unsupported-formats"
        case .selectedURLMissing: "selected-url-missing"
        case .unsupportedPlaybackPlan: "unsupported-playback-plan"
        }
    }
}

/// Pure selection policy shared by production downloads and focused regression tests.
/// Each call to `resolve(using:)` invokes the supplied resolver once, so a user retry
/// cannot accidentally reuse an expired CDN URL from an earlier attempt.
public enum OfflineAudioFormatSelector {
    /// All selected native plans are suitable for the sparse resource loader.
    /// Muxed MP4 may still require a post-download M4A export, but that export
    /// must never gate first audio.
    public static func supportsInstantPlayback(_ plan: OfflineAudioDownloadPlan) -> Bool {
        switch plan.source {
        case .directM4A, .directNativeAudio, .muxedMP4Extraction:
            true
        }
    }

    public static func requiresPostDownloadExport(_ plan: OfflineAudioDownloadPlan) -> Bool {
        plan.source != .directM4A
    }

    public static func resolve(
        using fetchFormats: @Sendable () async throws -> [VideoFormat]
    ) async throws -> OfflineAudioResolution {
        let formats = try await fetchFormats()
        return OfflineAudioResolution(formats: formats, plan: select(from: formats))
    }

    public static func select(from formats: [VideoFormat]) -> OfflineAudioDownloadPlan? {
        let downloadable = formats.filter { $0.url != nil }

        if let format = downloadable.filter({ isDirectM4A($0.mimeType) }).max(by: lowerBitrate) {
            return OfflineAudioDownloadPlan(
                source: .directM4A,
                format: format,
                downloadFileExtension: "m4a"
            )
        }

        if let format = downloadable.filter({ nativeAudioExtension(for: $0.mimeType) != nil }).max(by: lowerBitrate),
           let fileExtension = nativeAudioExtension(for: format.mimeType) {
            return OfflineAudioDownloadPlan(
                source: .directNativeAudio,
                format: format,
                downloadFileExtension: fileExtension
            )
        }

        // A muxed MP4 is larger than an audio-only stream, so choose the lowest
        // bitrate candidate. Its AAC track is subsequently exported to local M4A.
        if let format = downloadable.filter({ isMuxedMP4($0.mimeType) }).min(by: lowerBitrate) {
            return OfflineAudioDownloadPlan(
                source: .muxedMP4Extraction,
                format: format,
                downloadFileExtension: "mp4"
            )
        }

        return nil
    }

    /// Safe bounded diagnostics: MIME type, bitrate, and URL availability only.
    /// The URL itself and every query value are intentionally excluded.
    public static func safeFormatSummary(_ formats: [VideoFormat]) -> [String] {
        formats.map {
            "mime=\($0.mimeType) bitrate=\($0.bitrate ?? 0) hasURL=\($0.url != nil)"
        }
    }

    public static func unsupportedReason(for formats: [VideoFormat]) -> String {
        let audioFormats = formats.filter { $0.mimeType.hasPrefix("audio/") }
        if !audioFormats.isEmpty, audioFormats.allSatisfy({ $0.url == nil }) {
            return "Audio formats were returned, but YouTube did not provide a downloadable URL."
        }
        if audioFormats.contains(where: {
            $0.url != nil && $0.mimeType.hasPrefix("audio/webm") && $0.mimeType.contains("opus")
        }) {
            return "Only WebM/Opus audio is downloadable, and iOS cannot export that container with AVFoundation."
        }
        if audioFormats.contains(where: { $0.url != nil }) {
            return "The available audio format cannot be decoded by iOS."
        }
        return "No downloadable audio or compatible MP4 video stream was returned."
    }

    private static func isDirectM4A(_ mimeType: String) -> Bool {
        let value = mimeType.lowercased()
        guard value.hasPrefix("audio/mp4") || value.hasPrefix("audio/x-m4a") else {
            return false
        }
        // YouTube's standard AAC variants. ALAC/AC-3/E-AC-3 in an MP4 container
        // are also natively handled by AVFoundation when they are ever returned.
        return value.contains("mp4a") || value.contains("alac") ||
            value.contains("ac-3") || value.contains("ec-3") ||
            !value.contains("codecs=")
    }

    private static func nativeAudioExtension(for mimeType: String) -> String? {
        let value = mimeType.lowercased()
        if value.hasPrefix("audio/aac") { return "aac" }
        if value.hasPrefix("audio/mpeg") || value.hasPrefix("audio/mp3") { return "mp3" }
        return nil
    }

    private static func isMuxedMP4(_ mimeType: String) -> Bool {
        let value = mimeType.lowercased()
        return value.hasPrefix("video/mp4") && value.contains(", ") &&
            (value.contains("mp4a") || value.contains("alac") ||
             value.contains("ac-3") || value.contains("ec-3"))
    }

    private static func lowerBitrate(_ lhs: VideoFormat, _ rhs: VideoFormat) -> Bool {
        (lhs.bitrate ?? 0) < (rhs.bitrate ?? 0)
    }
}
