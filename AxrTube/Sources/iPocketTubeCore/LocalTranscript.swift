import Foundation

public enum TranscriptSource: String, Codable, Equatable, Sendable {
    case youtubeCaptions
    case appleTranslation
    case localSpeech
    case russianDubbing

    public var displayName: String {
        switch self {
        case .youtubeCaptions: "Русские субтитры YouTube"
        case .appleTranslation: "Перевод Apple на устройстве"
        case .localSpeech: "Локальная генерация"
        case .russianDubbing: "Локальная русская озвучка"
        }
    }
}

public enum LocalTranscriptionEligibility: Equatable, Sendable {
    case allowed
    case disabled
    case lowPowerMode
    case insufficientStorage
}

public enum LocalTranscriptionPermission: Equatable, Sendable {
    case notRequired
    case authorized
    case notDetermined
    case denied
    case restricted
}

public enum LocalTranscriptionPolicy {
    /// SpeechAnalyzer processes prerecorded files fully on device and does not
    /// require Speech or Microphone authorization.
    public static let requiredPermission: LocalTranscriptionPermission = .notRequired
    public static let minimumFreeBytes: Int64 = 256 * 1_024 * 1_024
}

public enum LocalTranscriptProgress: Equatable, Sendable {
    case preparingModel(Double)
    case recognizing(Double)
}

public enum LocalTranscriptionEngine: String, Codable, Equatable, Sendable {
    case parakeetTDTv2
    case speechAnalyzer
}

public enum LocalTranscriptFailure: Error, Equatable, Sendable {
    case permissionDenied
    case permissionRestricted
    case onDeviceRecognitionUnavailable
    case audioUnavailable
    case recognitionFailed
}

public struct LocalTranscriptRequest: Equatable, Sendable {
    public let videoID: String
    public let audioURL: URL
    public let localeIdentifier: String

    public init(videoID: String, audioURL: URL, localeIdentifier: String) {
        self.videoID = videoID
        self.audioURL = audioURL
        self.localeIdentifier = localeIdentifier
    }
}

public struct LocalTranscriptResult: Equatable, Sendable {
    public let cues: [CaptionCue]
    public let localeIdentifier: String
    public let wasCached: Bool
    public let engine: LocalTranscriptionEngine

    public init(
        cues: [CaptionCue],
        localeIdentifier: String,
        wasCached: Bool,
        engine: LocalTranscriptionEngine = .speechAnalyzer
    ) {
        self.cues = cues
        self.localeIdentifier = localeIdentifier
        self.wasCached = wasCached
        self.engine = engine
    }
}

public struct LocalSpeechSegment: Codable, Equatable, Hashable, Sendable {
    public let startTime: TimeInterval
    public let duration: TimeInterval
    public let text: String

    public init(startTime: TimeInterval, duration: TimeInterval, text: String) {
        self.startTime = startTime
        self.duration = duration
        self.text = text
    }
}

public enum LocalSpeechCuePolicy {
    public static func cues(from segments: [LocalSpeechSegment]) -> [CaptionCue] {
        var seen = Set<LocalSpeechSegment>()
        let clean = segments
            .filter { $0.startTime.isFinite && $0.duration.isFinite && $0.duration > 0 }
            .map {
                LocalSpeechSegment(
                    startTime: max(0, $0.startTime),
                    duration: $0.duration,
                    text: $0.text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
                )
            }
            .filter { !$0.text.isEmpty }
            .filter { seen.insert($0).inserted }
            .sorted { $0.startTime < $1.startTime }

        var result: [CaptionCue] = []
        var group: [LocalSpeechSegment] = []

        func flush() {
            guard let first = group.first, let last = group.last else { return }
            result.append(CaptionCue(
                startTime: first.startTime,
                endTime: max(first.startTime + 0.1, last.startTime + last.duration),
                text: group.map(\.text).joined(separator: " ")
            ))
            group.removeAll(keepingCapacity: true)
        }

        for segment in clean {
            if let first = group.first, let previous = group.last {
                let gap = segment.startTime - (previous.startTime + previous.duration)
                let groupDuration = segment.startTime + segment.duration - first.startTime
                let wordCount = group.reduce(0) { $0 + $1.text.split(separator: " ").count }
                if gap > 1.2 || groupDuration > 8 || wordCount >= 12 || previous.text.hasTerminalPunctuation {
                    flush()
                }
            }
            group.append(segment)
        }
        flush()
        return CaptionTranscriptPolicy.normalizedCues(result)
    }
}

public struct TranscriptExportDocument: Equatable, Sendable {
    public let title: String
    public let videoID: String
    public let source: TranscriptSource
    public let generatedAt: Date
    public let cues: [CaptionCue]

    public init(
        title: String,
        videoID: String,
        source: TranscriptSource,
        generatedAt: Date = Date(),
        cues: [CaptionCue]
    ) {
        self.title = title
        self.videoID = videoID
        self.source = source
        self.generatedAt = generatedAt
        self.cues = CaptionTranscriptPolicy.normalizedCues(cues)
    }

    public var videoURL: URL? {
        URL(string: "https://www.youtube.com/watch?v=\(videoID)")
    }

    public var safeBaseFilename: String {
        TranscriptExportPolicy.safeFilename(title.isEmpty ? "Стенограмма \(videoID)" : title)
    }

    public var plainText: String {
        let date = ISO8601DateFormatter().string(from: generatedAt)
        var lines = [
            title.isEmpty ? "Стенограмма" : title,
            "Видео: \(videoURL?.absoluteString ?? videoID)",
            "Источник: \(source.displayName)",
            "Дата: \(date)",
            "",
        ]
        lines.append(contentsOf: cues.map {
            "[\(TranscriptExportPolicy.timestamp($0.startTime))] \($0.text)"
        })
        return lines.joined(separator: "\n") + "\n"
    }

    public var pdfMetadata: [String: String] {
        [
            "Title": title.isEmpty ? "Стенограмма" : title,
            "Author": "AxrTube",
            "Subject": "\(source.displayName), \(videoURL?.absoluteString ?? videoID)",
            "Creator": "AxrTube",
        ]
    }
}

public enum TranscriptExportPolicy {
    public static func timestamp(_ time: TimeInterval) -> String {
        let total = max(0, Int(time.rounded(.down)))
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    public static func safeFilename(_ value: String) -> String {
        let disallowed = CharacterSet.alphanumerics
            .union(.whitespaces)
            .union(CharacterSet(charactersIn: "-_.()"))
            .inverted
        let cleaned = value
            .components(separatedBy: disallowed)
            .joined(separator: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let limited = String(cleaned.prefix(80)).trimmingCharacters(in: .whitespacesAndNewlines)
        return limited.isEmpty ? "Стенограмма" : limited
    }
}

private extension String {
    var hasTerminalPunctuation: Bool {
        guard let last else { return false }
        return ".!?;:…".contains(last)
    }
}
