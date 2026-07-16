import Foundation

/// Search request preference. The locale sent to YouTube improves candidate
/// relevance, but never counts as evidence for the language verdict.
public enum SearchLanguagePreference: Sendable, Equatable {
    case unrestricted
    case russian
}

/// Privacy-safe language evidence extracted from YouTube player metadata.
/// No media URLs, cookies, tokens or account identifiers are retained.
public struct VideoLanguageEvidence: Sendable, Equatable {
    public var audioLanguages: Set<String>
    public var defaultAudioLanguage: String?
    public var automaticCaptionLanguages: Set<String>
    public var manualCaptionLanguages: Set<String>

    public init(
        audioLanguages: Set<String> = [],
        defaultAudioLanguage: String? = nil,
        automaticCaptionLanguages: Set<String> = [],
        manualCaptionLanguages: Set<String> = []
    ) {
        self.audioLanguages = Set(audioLanguages.compactMap(Self.normalizedLanguageCode))
        self.defaultAudioLanguage = defaultAudioLanguage.flatMap(Self.normalizedLanguageCode)
        self.automaticCaptionLanguages = Set(automaticCaptionLanguages.compactMap(Self.normalizedLanguageCode))
        self.manualCaptionLanguages = Set(manualCaptionLanguages.compactMap(Self.normalizedLanguageCode))
    }

    public var hasExplicitEvidence: Bool {
        defaultAudioLanguage != nil || !audioLanguages.isEmpty || !automaticCaptionLanguages.isEmpty
    }

    public func merging(_ other: Self) -> Self {
        Self(
            audioLanguages: audioLanguages.union(other.audioLanguages),
            defaultAudioLanguage: defaultAudioLanguage ?? other.defaultAudioLanguage,
            automaticCaptionLanguages: automaticCaptionLanguages.union(other.automaticCaptionLanguages),
            manualCaptionLanguages: manualCaptionLanguages.union(other.manualCaptionLanguages)
        )
    }

    static func normalizedLanguageCode(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
            .lowercased()
        guard !value.isEmpty else { return nil }
        let primary = value.split(separator: "-", maxSplits: 1).first.map(String.init) ?? value
        guard (2...3).contains(primary.count), primary.allSatisfy(\.isLetter), primary != "und" else {
            return nil
        }
        return primary
    }
}

public enum VideoLanguageVerdict: Sendable, Equatable {
    case russian
    case nonRussian
    case unknown
}

/// One source of truth for strict Russian-language search.
public enum VideoLanguageClassifier {
    public static func verdict(for evidence: VideoLanguageEvidence) -> VideoLanguageVerdict {
        var explicitAudio = evidence.audioLanguages
        if let language = evidence.defaultAudioLanguage { explicitAudio.insert(language) }
        if explicitAudio.contains("ru") { return .russian }
        if !explicitAudio.isEmpty { return .nonRussian }

        // ASR captions are generated from the spoken track and therefore are useful
        // speech evidence. Manual/translated captions are recorded but intentionally
        // do not prove the language of the audio.
        if evidence.automaticCaptionLanguages.contains("ru") { return .russian }
        if !evidence.automaticCaptionLanguages.isEmpty { return .nonRussian }
        return .unknown
    }

    public static func includes(
        evidence: VideoLanguageEvidence,
        preference: SearchLanguagePreference
    ) -> Bool {
        preference == .unrestricted || verdict(for: evidence) == .russian
    }
}

/// Parser is independent from the player model so search can enrich metadata
/// without validating or retaining stream URLs.
public enum VideoLanguageEvidenceParser {
    public static func parse(_ json: [String: Any]) -> VideoLanguageEvidence {
        var audio = Set<String>()
        var automaticCaptions = Set<String>()
        var manualCaptions = Set<String>()
        var defaultAudio: String?

        func addAudioTrack(_ track: [String: Any], isDefault: Bool = false) {
            let candidates = [
                track["languageCode"] as? String,
                track["id"] as? String,
                track["audioTrackId"] as? String,
                plainText(track["displayName"]),
                plainText(track["name"]),
            ].compactMap { $0 }
            for candidate in candidates {
                if let code = languageCode(from: candidate) {
                    audio.insert(code)
                    if isDefault || (track["audioIsDefault"] as? Bool == true) { defaultAudio = code }
                }
            }
        }

        let streaming = json["streamingData"] as? [String: Any]
        let formats = (streaming?["formats"] as? [[String: Any]] ?? [])
            + (streaming?["adaptiveFormats"] as? [[String: Any]] ?? [])
        for format in formats {
            if let track = format["audioTrack"] as? [String: Any] { addAudioTrack(track) }
        }

        let details = json["videoDetails"] as? [String: Any]
        for key in ["defaultAudioLanguage", "audioLanguage"] {
            if let raw = details?[key] as? String, let code = languageCode(from: raw) {
                audio.insert(code)
                defaultAudio = code
            }
        }

        let renderer = (json["microformat"] as? [String: Any])?["playerMicroformatRenderer"] as? [String: Any]
        if defaultAudio == nil,
           let raw = renderer?["defaultAudioLanguage"] as? String,
           let code = languageCode(from: raw) {
            audio.insert(code)
            defaultAudio = code
        }

        if let trackList = (json["captions"] as? [String: Any])?["playerCaptionsTracklistRenderer"] as? [String: Any] {
            let audioTracks = trackList["audioTracks"] as? [[String: Any]] ?? []
            let defaultIndex = trackList["defaultAudioTrackIndex"] as? Int
            for (index, track) in audioTracks.enumerated() {
                addAudioTrack(track, isDefault: index == defaultIndex)
            }

            for track in trackList["captionTracks"] as? [[String: Any]] ?? [] {
                guard let raw = track["languageCode"] as? String,
                      let code = languageCode(from: raw) else { continue }
                let vssID = track["vssId"] as? String ?? ""
                let isAutomatic = (track["kind"] as? String) == "asr" || vssID.hasPrefix("a.")
                if isAutomatic { automaticCaptions.insert(code) }
                else { manualCaptions.insert(code) }
            }
        }

        return VideoLanguageEvidence(
            audioLanguages: audio,
            defaultAudioLanguage: defaultAudio,
            automaticCaptionLanguages: automaticCaptions,
            manualCaptionLanguages: manualCaptions
        )
    }

    private static func languageCode(from raw: String) -> String? {
        let lowered = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lowered.contains("русск") || lowered.contains("russian") { return "ru" }
        if lowered.contains("англий") || lowered.contains("english") { return "en" }
        let prefix = lowered.split(separator: ".", maxSplits: 1).first.map(String.init) ?? lowered
        return VideoLanguageEvidence.normalizedLanguageCode(prefix)
    }

    private static func plainText(_ value: Any?) -> String? {
        if let string = value as? String { return string }
        guard let object = value as? [String: Any] else { return nil }
        if let simple = object["simpleText"] as? String { return simple }
        if let runs = object["runs"] as? [[String: Any]] {
            let text = runs.compactMap { $0["text"] as? String }.joined()
            return text.isEmpty ? nil : text
        }
        return nil
    }
}

public actor VideoLanguageEvidenceCache {
    public static let shared = VideoLanguageEvidenceCache()

    private struct Entry {
        let evidence: VideoLanguageEvidence
        let expiresAt: Date
    }

    private var entries: [String: Entry] = [:]
    private var inFlight: [String: Task<VideoLanguageEvidence, Never>] = [:]
    private let ttl: TimeInterval

    public init(ttl: TimeInterval = 6 * 60 * 60) { self.ttl = ttl }

    public func evidence(
        for videoID: String,
        loader: @escaping @Sendable () async -> VideoLanguageEvidence
    ) async -> VideoLanguageEvidence {
        if let entry = entries[videoID], entry.expiresAt > Date() { return entry.evidence }
        if let task = inFlight[videoID] { return await task.value }

        let task = Task { await loader() }
        inFlight[videoID] = task
        let evidence = await task.value
        inFlight[videoID] = nil
        entries[videoID] = Entry(evidence: evidence, expiresAt: Date().addingTimeInterval(ttl))
        return evidence
    }
}
