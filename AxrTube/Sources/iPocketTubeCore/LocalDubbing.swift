import Foundation

public enum LocalDubbingTranscriptOrigin: String, Codable, Equatable, Sendable {
    case youtubeCaptions
    case parakeet
    case speechAnalyzer

    public var displayName: String {
        switch self {
        case .youtubeCaptions: "Субтитры YouTube"
        case .parakeet: "Parakeet TDT v2, локально"
        case .speechAnalyzer: "Apple SpeechAnalyzer, локально"
        }
    }
}

public enum LocalDubbingVoiceEngine: String, Codable, Equatable, Sendable {
    case supertonic3
    case avSpeechSynthesizer

    public var displayName: String {
        switch self {
        case .supertonic3: "Supertonic 3"
        case .avSpeechSynthesizer: "Системный голос Apple"
        }
    }
}

public enum LocalDubbingSourceLanguage: String, Codable, Equatable, Sendable {
    case russian = "ru"
    case english = "en"
    case other
    case unknown

    public var translationBypassed: Bool { self == .russian }
}

public enum LocalDubbingTranslationAvailability: Equatable, Sendable {
    case installed
    case supported
    case unsupported
}

public enum LocalDubbingTranslationLifecycleAction: Equatable, Sendable {
    case translate
    case prepare
    case failUnsupported
}

public struct LocalDubbingLanguageDecision: Codable, Equatable, Sendable {
    public let language: LocalDubbingSourceLanguage
    public let confidence: Double
    public let usedOverride: Bool
    public let metadataLanguageCode: String?
    public let detectedLanguageCode: String?

    public init(
        language: LocalDubbingSourceLanguage,
        confidence: Double,
        usedOverride: Bool,
        metadataLanguageCode: String?,
        detectedLanguageCode: String?
    ) {
        self.language = language
        self.confidence = min(1, max(0, confidence))
        self.usedOverride = usedOverride
        self.metadataLanguageCode = metadataLanguageCode
        self.detectedLanguageCode = detectedLanguageCode
    }
}

public struct LocalDubbingLanguageEvidence: Equatable, Sendable {
    public let languageCode: String?
    public let confidence: Double
    public let sampledLetterCount: Int

    public init(languageCode: String?, confidence: Double, sampledLetterCount: Int) {
        self.languageCode = languageCode
        self.confidence = min(1, max(0, confidence))
        self.sampledLetterCount = max(0, sampledLetterCount)
    }
}

public enum LocalDubbingStage: Equatable, Sendable {
    case idle
    case waitingForAudio
    case preparingAudio
    case determiningLanguage
    case preparingASR(progress: Double)
    case transcribing(progress: Double)
    case preparingTranslationAssets
    case preparingTranslation
    case translating(progress: Double)
    case preparingVoice(progress: Double)
    case synthesizing(progress: Double)
    case assembling(progress: Double)
    case validating
    case ready
    case cancelled
    case failed(message: String)

    public var progress: Double {
        switch self {
        case .idle, .waitingForAudio, .preparingAudio, .determiningLanguage,
             .preparingTranslationAssets, .preparingTranslation, .validating: 0
        case .preparingASR(let value), .transcribing(let value),
             .translating(let value), .preparingVoice(let value),
             .synthesizing(let value), .assembling(let value):
            min(1, max(0, value))
        case .ready: 1
        case .cancelled, .failed: 0
        }
    }

    public var title: String {
        switch self {
        case .idle: "Русская озвучка"
        case .waitingForAudio, .preparingAudio: "Подготавливаем аудио"
        case .determiningLanguage: "Определяем язык"
        case .preparingASR, .transcribing: "Расшифровываем аудио"
        case .preparingTranslationAssets: "Подготавливаем перевод с английского на русский"
        case .preparingTranslation, .translating: "Переводим текст на русский"
        case .preparingVoice: "Загружаем голос"
        case .synthesizing: "Озвучиваем текст"
        case .assembling: "Собираем аудиодорожку"
        case .validating: "Проверяем и сохраняем"
        case .ready: "Готово"
        case .cancelled: "Создание озвучки отменено"
        case .failed: "Не удалось создать озвучку"
        }
    }

    public var isActive: Bool {
        switch self {
        case .waitingForAudio, .preparingAudio, .determiningLanguage,
             .preparingASR, .transcribing, .preparingTranslation,
             .preparingTranslationAssets,
             .translating, .preparingVoice, .synthesizing, .assembling, .validating:
            true
        default:
            false
        }
    }
}

public enum LocalDubbingProgressPhase: CaseIterable, Equatable, Sendable {
    case preparingAudio
    case determiningLanguage
    case preparingASR
    case transcribing
    case translation
    case preparingVoice
    case synthesis
    case assembly
    case validation
}

public struct LocalDubbingProgressPlan: Equatable, Sendable {
    public let requiresASR: Bool
    public let requiresTranslation: Bool

    public init(requiresASR: Bool, requiresTranslation: Bool) {
        self.requiresASR = requiresASR
        self.requiresTranslation = requiresTranslation
    }

    public func overallProgress(
        phase: LocalDubbingProgressPhase,
        phaseProgress: Double
    ) -> Double {
        let active = LocalDubbingProgressPhase.allCases.filter { weight(for: $0) > 0 }
        let total = active.reduce(0) { $0 + weight(for: $1) }
        guard total > 0 else { return 0 }
        let completed = active.prefix { $0 != phase }.reduce(0) { $0 + weight(for: $1) }
        guard active.contains(phase) else { return min(0.99, completed / total) }
        let local = min(1, max(0, phaseProgress))
        return min(0.99, (completed + weight(for: phase) * local) / total)
    }

    private func weight(for phase: LocalDubbingProgressPhase) -> Double {
        switch phase {
        case .preparingAudio: 2
        case .determiningLanguage: 3
        case .preparingASR: requiresASR ? 10 : 0
        case .transcribing: requiresASR ? 25 : 0
        case .translation: requiresTranslation ? 15 : 0
        case .preparingVoice: 10
        case .synthesis: 70
        case .assembly: 7
        case .validation: 3
        }
    }
}

public struct LocalDubbingProgressUpdate: Equatable, Sendable {
    public let stage: LocalDubbingStage
    public let overallProgress: Double
    public let completedSegments: Int?
    public let totalSegments: Int?
    public let resumedFromSegments: Int
    public let isRussianDirect: Bool

    public init(
        stage: LocalDubbingStage,
        overallProgress: Double,
        completedSegments: Int? = nil,
        totalSegments: Int? = nil,
        resumedFromSegments: Int = 0,
        isRussianDirect: Bool = false
    ) {
        self.stage = stage
        self.overallProgress = stage == .ready ? 1 : min(0.99, max(0, overallProgress))
        self.completedSegments = completedSegments
        self.totalSegments = totalSegments
        self.resumedFromSegments = resumedFromSegments
        self.isRussianDirect = isRussianDirect
    }

    public var statusText: String {
        guard case .synthesizing = stage,
              let completedSegments, let totalSegments else { return stage.title }
        if resumedFromSegments > 0, completedSegments <= resumedFromSegments {
            return "Продолжаем озвучку, готово \(completedSegments) из \(totalSegments)"
        }
        if isRussianDirect {
            return "Озвучиваем русский текст, фрагмент \(completedSegments) из \(totalSegments)"
        }
        return "Озвучиваем фрагмент \(completedSegments) из \(totalSegments)"
    }

    public var detailText: String {
        switch stage {
        case .preparingASR, .transcribing:
            return "Создаём исходную стенограмму из локальной аудиодорожки."
        case .preparingTranslationAssets:
            return "Маршрут: Английский -> русский. iPhone подготавливает системный перевод."
        case .preparingTranslation, .translating:
            return "Маршрут: Английский -> русский. Переводим готовую стенограмму."
        case .preparingVoice:
            return "Подготавливаем локальный русский голос."
        case .synthesizing:
            return isRussianDirect
                ? "Создаём аудиодорожку из готовой русской стенограммы."
                : "Создаём русскую аудиодорожку из переведённого текста."
        case .assembling:
            return "Объединяем готовые фрагменты в одну аудиодорожку."
        case .validating:
            return "Проверяем результат и атомарно сохраняем его на iPhone."
        default:
            return "Исходное аудио и текст не покидают iPhone."
        }
    }

    public var accessibilityAnnouncementKey: String {
        switch stage {
        case .preparingASR, .transcribing: "transcription"
        case .preparingTranslationAssets: "translation-assets"
        case .preparingTranslation, .translating: "translation"
        case .synthesizing: "synthesis"
        case .waitingForAudio, .preparingAudio: "audio"
        default: String(describing: stage).split(separator: "(").first.map(String.init) ?? stage.title
        }
    }
}

public enum LocalDubbingAccessibilityPolicy {
    public static func shouldAnnounce(
        previous: LocalDubbingProgressUpdate?,
        current: LocalDubbingProgressUpdate
    ) -> Bool {
        previous?.accessibilityAnnouncementKey != current.accessibilityAnnouncementKey
    }
}

public struct LocalDubbingMetrics: Codable, Equatable, Sendable {
    public let wallTime: TimeInterval
    public let minimumAvailableMemoryBytes: UInt64
    public let peakResidentMemoryBytes: UInt64
    public let modelCacheBytes: Int64
    public let outputBytes: Int64
    public let startingThermalState: Int
    public let endingThermalState: Int

    public init(
        wallTime: TimeInterval,
        minimumAvailableMemoryBytes: UInt64,
        peakResidentMemoryBytes: UInt64,
        modelCacheBytes: Int64,
        outputBytes: Int64,
        startingThermalState: Int,
        endingThermalState: Int
    ) {
        self.wallTime = wallTime
        self.minimumAvailableMemoryBytes = minimumAvailableMemoryBytes
        self.peakResidentMemoryBytes = peakResidentMemoryBytes
        self.modelCacheBytes = modelCacheBytes
        self.outputBytes = outputBytes
        self.startingThermalState = startingThermalState
        self.endingThermalState = endingThermalState
    }
}

public struct LocalDubbingResult: Codable, Equatable, Sendable {
    public let algorithmVersion: Int
    public let videoID: String
    public let title: String
    public let createdAt: Date
    public let cues: [CaptionCue]
    public let transcriptOrigin: LocalDubbingTranscriptOrigin
    public let sourceLanguage: LocalDubbingSourceLanguage
    public let translationBypassed: Bool
    public let cacheIdentity: String
    public let voiceEngine: LocalDubbingVoiceEngine
    public let audioFilename: String
    public let transcriptFilename: String
    public let metrics: LocalDubbingMetrics

    public init(
        algorithmVersion: Int = LocalDubbingPolicy.algorithmVersion,
        videoID: String,
        title: String,
        createdAt: Date = Date(),
        cues: [CaptionCue],
        transcriptOrigin: LocalDubbingTranscriptOrigin,
        sourceLanguage: LocalDubbingSourceLanguage = .english,
        translationBypassed: Bool = false,
        cacheIdentity: String = "legacy",
        voiceEngine: LocalDubbingVoiceEngine,
        audioFilename: String,
        transcriptFilename: String,
        metrics: LocalDubbingMetrics
    ) {
        self.algorithmVersion = algorithmVersion
        self.videoID = videoID
        self.title = title
        self.createdAt = createdAt
        self.cues = CaptionTranscriptPolicy.normalizedCues(cues)
        self.transcriptOrigin = transcriptOrigin
        self.sourceLanguage = sourceLanguage
        self.translationBypassed = translationBypassed
        self.cacheIdentity = cacheIdentity
        self.voiceEngine = voiceEngine
        self.audioFilename = audioFilename
        self.transcriptFilename = transcriptFilename
        self.metrics = metrics
    }
}

public enum LocalDubbingFailure: Error, Equatable, Sendable {
    case audioUnavailable
    case sourceTranscriptUnavailable
    case translationPreparationRequired
    case translationPreparationFailed
    case translationPairUnsupported
    case translationFailed
    case jobAlreadyActive
    case voiceAssetsUnavailable
    case synthesisFailed
    case exportFailed
    case insufficientStorage
    case thermalPressure
    case sourceLanguageChoiceRequired

    public var userMessage: String {
        switch self {
        case .audioUnavailable: "Локальная аудиодорожка ещё не готова. Оставьте ролик открытым до завершения загрузки."
        case .sourceTranscriptUnavailable: "Не удалось получить исходную стенограмму из субтитров или локального распознавания."
        case .translationPreparationRequired: "Подготавливаем перевод с английского на русский."
        case .translationPreparationFailed: "Не удалось подготовить перевод с английского на русский. Проверьте подключение и повторите."
        case .translationPairUnsupported: "Системный перевод с английского на русский недоступен на этом iPhone."
        case .translationFailed: "Локальный перевод EN-RU завершился ошибкой."
        case .jobAlreadyActive: "Русская озвучка для этого видео уже создаётся."
        case .voiceAssetsUnavailable: "Модель русского голоса не подготовлена и системный голос недоступен."
        case .synthesisFailed: "Не удалось синтезировать русскую речь."
        case .exportFailed: "Не удалось собрать локальный аудиофайл."
        case .insufficientStorage: "Недостаточно свободного места для моделей и готового аудиофайла."
        case .thermalPressure: "Устройство слишком нагрелось. Продолжите после охлаждения iPhone."
        case .sourceLanguageChoiceRequired: "Выберите язык исходной стенограммы."
        }
    }
}

public struct LocalDubbingRequest: Equatable, Sendable {
    public let videoID: String
    public let title: String
    public let sourceAudioURL: URL
    public let availableSourceCues: [CaptionCue]
    public let availableSourceOrigin: LocalDubbingTranscriptOrigin?
    public let sourceCaptionLanguageCode: String?
    public let sourceLanguageOverride: String?
    public let maximumSourceDuration: TimeInterval?

    public init(
        videoID: String,
        title: String,
        sourceAudioURL: URL,
        availableSourceCues: [CaptionCue] = [],
        availableSourceOrigin: LocalDubbingTranscriptOrigin? = nil,
        sourceCaptionLanguageCode: String? = nil,
        sourceLanguageOverride: String? = nil,
        maximumSourceDuration: TimeInterval? = nil
    ) {
        self.videoID = videoID
        self.title = title
        self.sourceAudioURL = sourceAudioURL
        self.availableSourceCues = availableSourceCues
        self.availableSourceOrigin = availableSourceOrigin
        self.sourceCaptionLanguageCode = sourceCaptionLanguageCode
        self.sourceLanguageOverride = sourceLanguageOverride
        self.maximumSourceDuration = maximumSourceDuration
    }
}

public enum LocalDubbingWorkPhase: String, Codable, Equatable, Sendable {
    case sourceTranscript
    case translation
    case synthesis
    case assembly
}

public struct LocalDubbingWorkManifest: Codable, Equatable, Sendable {
    public static let schemaVersion = 1

    public let schemaVersion: Int
    public let algorithmVersion: Int
    public var cacheIdentity: String
    public let videoID: String
    public let title: String
    public let createdAt: Date
    public var updatedAt: Date
    public var phase: LocalDubbingWorkPhase
    public var sourceCues: [CaptionCue]
    public var transcriptOrigin: LocalDubbingTranscriptOrigin?
    public var sourceLanguageDecision: LocalDubbingLanguageDecision?
    public var translationBypassed: Bool
    public var translationsByIndex: [Int: String]
    public var voiceEngine: LocalDubbingVoiceEngine?
    public var completedSegmentIndices: Set<Int>

    public init(
        schemaVersion: Int = Self.schemaVersion,
        algorithmVersion: Int = LocalDubbingPolicy.algorithmVersion,
        cacheIdentity: String,
        videoID: String,
        title: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        phase: LocalDubbingWorkPhase = .sourceTranscript,
        sourceCues: [CaptionCue] = [],
        transcriptOrigin: LocalDubbingTranscriptOrigin? = nil,
        sourceLanguageDecision: LocalDubbingLanguageDecision? = nil,
        translationBypassed: Bool = false,
        translationsByIndex: [Int: String] = [:],
        voiceEngine: LocalDubbingVoiceEngine? = nil,
        completedSegmentIndices: Set<Int> = []
    ) {
        self.schemaVersion = schemaVersion
        self.algorithmVersion = algorithmVersion
        self.cacheIdentity = cacheIdentity
        self.videoID = videoID
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.phase = phase
        self.sourceCues = sourceCues
        self.transcriptOrigin = transcriptOrigin
        self.sourceLanguageDecision = sourceLanguageDecision
        self.translationBypassed = translationBypassed
        self.translationsByIndex = translationsByIndex
        self.voiceEngine = voiceEngine
        self.completedSegmentIndices = completedSegmentIndices
    }

    public var isCompatible: Bool {
        schemaVersion == Self.schemaVersion
            && algorithmVersion == LocalDubbingPolicy.algorithmVersion
    }
}

public struct LocalDubbingPlaybackSnapshot: Codable, Equatable, Sendable {
    public let algorithmVersion: Int
    public let videoID: String
    public var position: TimeInterval
    public var duration: TimeInterval
    public var wasPlaying: Bool
    public var isSelected: Bool
    public var updatedAt: Date

    public init(
        algorithmVersion: Int = LocalDubbingPolicy.algorithmVersion,
        videoID: String,
        position: TimeInterval,
        duration: TimeInterval,
        wasPlaying: Bool,
        isSelected: Bool = true,
        updatedAt: Date = Date()
    ) {
        self.algorithmVersion = algorithmVersion
        self.videoID = videoID
        self.position = position
        self.duration = duration
        self.wasPlaying = wasPlaying
        self.isSelected = isSelected
        self.updatedAt = updatedAt
    }
}

public enum LocalDubbingPolicy {
    public static let algorithmVersion = 5
    public static let minimumFreeBytes: Int64 = 1_200 * 1_024 * 1_024
    public static let translationBatchSize = 24
    public static let playbackRate: Float = 1.0

    public static func usableEnglishCaptions(
        cues: [CaptionCue],
        languageCode: String?
    ) -> [CaptionCue]? {
        guard let languageCode,
              languageCode.lowercased().split(separator: "-").first == "en" else { return nil }
        let normalized = CaptionTranscriptPolicy.normalizedCues(cues)
        return normalized.isEmpty ? nil : normalized
    }

    public static func usableSourceCaptions(
        cues: [CaptionCue],
        languageCode: String?
    ) -> [CaptionCue]? {
        guard sourceLanguage(for: languageCode) == .english
                || sourceLanguage(for: languageCode) == .russian else { return nil }
        let normalized = CaptionTranscriptPolicy.normalizedCues(cues)
        return normalized.isEmpty ? nil : normalized
    }

    public static func usableSourceTranscript(cues: [CaptionCue]) -> [CaptionCue]? {
        let normalized = CaptionTranscriptPolicy.normalizedCues(cues)
        return normalized.isEmpty ? nil : normalized
    }

    public static func scriptLanguageEvidence(in cues: [CaptionCue]) -> LocalDubbingLanguageEvidence {
        let scalars = cues.prefix(80).flatMap { $0.text.unicodeScalars }
        var latin = 0
        var cyrillic = 0
        for scalar in scalars {
            switch scalar.value {
            case 0x0041...0x005A, 0x0061...0x007A:
                latin += 1
            case 0x0400...0x052F:
                cyrillic += 1
            default:
                break
            }
        }
        let total = latin + cyrillic
        guard cues.count >= 3, total >= 120 else {
            return LocalDubbingLanguageEvidence(
                languageCode: nil,
                confidence: 0,
                sampledLetterCount: total
            )
        }
        let latinShare = Double(latin) / Double(total)
        let cyrillicShare = Double(cyrillic) / Double(total)
        if latinShare >= 0.85 {
            return LocalDubbingLanguageEvidence(
                languageCode: "en",
                confidence: latinShare,
                sampledLetterCount: total
            )
        }
        if cyrillicShare >= 0.85 {
            return LocalDubbingLanguageEvidence(
                languageCode: "ru",
                confidence: cyrillicShare,
                sampledLetterCount: total
            )
        }
        return LocalDubbingLanguageEvidence(
            languageCode: nil,
            confidence: max(latinShare, cyrillicShare),
            sampledLetterCount: total
        )
    }

    public static func sourceLanguage(for rawCode: String?) -> LocalDubbingSourceLanguage {
        guard let rawCode else { return .unknown }
        let primary = rawCode
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
            .split(separator: "-", maxSplits: 1)
            .first
            .map(String.init)
        switch primary {
        case "ru": return .russian
        case "en": return .english
        case nil, "", "und", "original": return .unknown
        default: return .other
        }
    }

    public static func languageDecision(
        metadataLanguageCode: String?,
        overrideLanguageCode: String?,
        detectedLanguageCode: String?,
        detectedConfidence: Double
    ) -> LocalDubbingLanguageDecision {
        let detected = sourceLanguage(for: detectedLanguageCode)
        let confidentDetection = detectedConfidence >= 0.85
            && (detected == .russian || detected == .english)
        if confidentDetection {
            return LocalDubbingLanguageDecision(
                language: detected,
                confidence: detectedConfidence,
                usedOverride: false,
                metadataLanguageCode: metadataLanguageCode,
                detectedLanguageCode: detectedLanguageCode
            )
        }

        let metadata = sourceLanguage(for: metadataLanguageCode)
        if metadata == .russian || metadata == .english {
            return LocalDubbingLanguageDecision(
                language: metadata,
                confidence: 1,
                usedOverride: false,
                metadataLanguageCode: metadataLanguageCode,
                detectedLanguageCode: detectedLanguageCode
            )
        }

        let override = sourceLanguage(for: overrideLanguageCode)
        if override == .russian || override == .english {
            return LocalDubbingLanguageDecision(
                language: override,
                confidence: 1,
                usedOverride: true,
                metadataLanguageCode: metadataLanguageCode,
                detectedLanguageCode: detectedLanguageCode
            )
        }
        return LocalDubbingLanguageDecision(
            language: .unknown,
            confidence: detectedConfidence,
            usedOverride: false,
            metadataLanguageCode: metadataLanguageCode,
            detectedLanguageCode: detectedLanguageCode
        )
    }

    public static func languageCacheComponent(
        language: LocalDubbingSourceLanguage,
        translationBypassed: Bool
    ) -> String {
        "source=\(language.rawValue)|translationBypassed=\(translationBypassed)"
    }

    public static func cacheIdentityPayload(for request: LocalDubbingRequest) throws -> Data {
        var payload = Data()
        payload.append(Data("v=\(algorithmVersion)|".utf8))
        payload.append(Data(request.videoID.utf8))
        payload.append(Data("|\(request.maximumSourceDuration ?? -1)".utf8))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        payload.append(try encoder.encode(request.availableSourceCues))
        payload.append(Data("|\(request.availableSourceOrigin?.rawValue ?? "")".utf8))
        payload.append(Data("|\(request.sourceCaptionLanguageCode ?? "")".utf8))
        let declaredLanguage = sourceLanguage(
            for: request.sourceLanguageOverride ?? request.sourceCaptionLanguageCode
        )
        payload.append(Data("|\(request.sourceLanguageOverride ?? "")".utf8))
        let languageComponent = languageCacheComponent(
            language: declaredLanguage,
            translationBypassed: declaredLanguage.translationBypassed
        )
        payload.append(Data("|\(languageComponent)".utf8))
        return payload
    }

    public static func weightedSegmentCompletion(
        cues: [CaptionCue],
        completed: Set<Int>
    ) -> Double {
        guard !cues.isEmpty else { return 0 }
        let weights = cues.map { max(1, $0.text.unicodeScalars.count) }
        let total = weights.reduce(0, +)
        guard total > 0 else { return 0 }
        let done = completed.reduce(0) { partial, index in
            guard cues.indices.contains(index) else { return partial }
            return partial + weights[index]
        }
        return min(1, max(0, Double(done) / Double(total)))
    }

    public static func shouldTranslate(_ decision: LocalDubbingLanguageDecision) -> Bool {
        decision.language == .english
    }

    public static func canBypassTranslation(
        cues: [CaptionCue],
        decision: LocalDubbingLanguageDecision
    ) -> Bool {
        guard decision.language == .russian else { return false }
        let evidence = scriptLanguageEvidence(in: cues)
        return evidence.languageCode != "en" || evidence.confidence < 0.85
    }

    public static func shouldReuseReadyResult(
        activeVideoID: String?,
        requestVideoID: String,
        requestedLanguage: LocalDubbingSourceLanguage,
        resultLanguage: LocalDubbingSourceLanguage
    ) -> Bool {
        activeVideoID == requestVideoID
            && (requestedLanguage == .unknown || requestedLanguage == resultLanguage)
    }

    public static func translatedCues(
        source: [CaptionCue],
        translationsByIdentifier: [String: String]
    ) -> [CaptionCue] {
        CaptionTranscriptPolicy.normalizedCues(source.enumerated().compactMap { index, cue in
            guard let text = translationsByIdentifier[String(index)]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else { return nil }
            return CaptionCue(startTime: cue.startTime, endTime: cue.endTime, text: text)
        })
    }

    public static func scheduledStart(
        cueStart: TimeInterval,
        previousSegmentEnd: TimeInterval
    ) -> TimeInterval {
        max(0, max(cueStart, previousSegmentEnd))
    }

    public static func normalizedSeek(
        _ requested: TimeInterval,
        duration: TimeInterval
    ) -> TimeInterval {
        guard requested.isFinite, duration.isFinite, duration > 0 else { return 0 }
        return min(max(0, requested), duration)
    }

    public static func firstIncompleteSegment(
        total: Int,
        completed: Set<Int>,
        valid: (Int) -> Bool
    ) -> Int? {
        guard total > 0 else { return nil }
        return (0..<total).first { !completed.contains($0) || !valid($0) }
    }

    public static func pendingSegmentIndices(
        total: Int,
        completed: Set<Int>,
        valid: (Int) -> Bool
    ) -> [Int] {
        guard total > 0 else { return [] }
        return (0..<total).filter { !completed.contains($0) || !valid($0) }
    }

    public static func batches<T>(_ values: [T], size: Int = translationBatchSize) -> [[T]] {
        guard size > 0, !values.isEmpty else { return [] }
        return stride(from: 0, to: values.count, by: size).map {
            Array(values[$0..<min($0 + size, values.count)])
        }
    }

    public static func safeVideoID(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let clean = value.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "_" }
        let result = String(clean.prefix(120))
        return result.isEmpty ? "unknown" : result
    }
}

public enum LocalDubbingAudioOwnershipPolicy {
    public static func shouldPauseSource(localPlaybackWillStart: Bool) -> Bool {
        localPlaybackWillStart
    }

    public static func effectivePlaybackRate() -> Float {
        LocalDubbingPolicy.playbackRate
    }

    public static func shouldSuppressSourceRate(
        localPlaybackIsActive: Bool,
        sourceRate: Float
    ) -> Bool {
        localPlaybackIsActive && sourceRate > 0
    }
}

public enum LocalDubbingTranscriptSurface: Equatable, Sendable {
    case source
    case localProgress
    case russianTranscript
    case localFailure
    case localCancelled
}

public enum LocalDubbingPresentationPolicy {
    public static func transcriptSurface(
        stage: LocalDubbingStage,
        hasResult: Bool,
        prefersRussian: Bool
    ) -> LocalDubbingTranscriptSurface {
        guard prefersRussian else { return .source }
        if stage.isActive { return .localProgress }
        if stage == .ready, hasResult { return .russianTranscript }
        if case .failed = stage { return .localFailure }
        if stage == .cancelled { return .localCancelled }
        return .source
    }

    public static func transcriptHeaderLabel(cues: [CaptionCue], count: Int) -> String {
        let evidence = LocalDubbingPolicy.scriptLanguageEvidence(in: cues)
        if evidence.languageCode == "ru", evidence.confidence >= 0.85 {
            return "Русская стенограмма, реплик: \(count)"
        }
        return "Стенограмма озвучки, реплик: \(count)"
    }

    public static func showsPrimaryStartAction(
        stage: LocalDubbingStage,
        failure: LocalDubbingFailure?
    ) -> Bool {
        guard failure != .sourceLanguageChoiceRequired else { return false }
        if case .failed = stage { return false }
        return !stage.isActive && stage != .ready
    }

    public static func visibleProgressIndicatorCount(stage: LocalDubbingStage) -> Int {
        stage.isActive ? 1 : 0
    }

    public static func usesIndeterminateProgress(stage: LocalDubbingStage) -> Bool {
        stage == .preparingTranslationAssets
    }

    public static func showsTranslationRetry(failure: LocalDubbingFailure?) -> Bool {
        failure == .translationPreparationFailed
    }
}

public enum LocalDubbingTranslationPolicy {
    public static func action(
        for availability: LocalDubbingTranslationAvailability
    ) -> LocalDubbingTranslationLifecycleAction {
        switch availability {
        case .installed: .translate
        case .supported: .prepare
        case .unsupported: .failUnsupported
        }
    }

    public static func shouldBeginPreparation(
        isPreparing: Bool,
        hasConfiguration: Bool
    ) -> Bool {
        !isPreparing && hasConfiguration
    }
}

public actor LocalDubbingJobArbiter {
    public static let shared = LocalDubbingJobArbiter()

    private var owners: [String: UUID] = [:]

    public init() {}

    public func acquire(videoID: String, token: UUID) -> Bool {
        guard owners[videoID] == nil else { return false }
        owners[videoID] = token
        return true
    }

    public func release(videoID: String, token: UUID) {
        guard owners[videoID] == token else { return }
        owners[videoID] = nil
    }

    public func isOwned(videoID: String) -> Bool {
        owners[videoID] != nil
    }
}
