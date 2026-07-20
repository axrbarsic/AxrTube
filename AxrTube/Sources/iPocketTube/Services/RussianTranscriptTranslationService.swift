#if os(iOS)
import Foundation
import Observation
@preconcurrency import Translation
import iPocketTubeCore

@MainActor
@Observable
public final class RussianTranscriptTranslationService: RussianTranscriptTranslating {
    public private(set) var configuration: TranslationSession.Configuration?
    public private(set) var runtimeAvailability: String = "unchecked"

    @ObservationIgnored private let cache: RussianTranscriptCache
    @ObservationIgnored private let languageAvailability = LanguageAvailability()
    @ObservationIgnored private var sessionContinuation: CheckedContinuation<TranslationSession, Error>?
    @ObservationIgnored private var workQueue: RussianTranscriptWorkQueue?
    @ObservationIgnored private var activeRequestKey: String?
    @ObservationIgnored private var isPreparingSession = false

    public init(cacheBaseDirectory: URL? = nil) {
        cache = RussianTranscriptCache(baseDirectory: cacheBaseDirectory)
    }

    public func updatePriority(playbackTime: TimeInterval) {
        workQueue?.reprioritize(playbackTime: playbackTime)
    }

    public func refreshRuntimeAvailability() async -> String {
        let source = Locale.Language(identifier: "en")
        let target = Locale.Language(identifier: "ru")
        let status = await languageAvailability.status(from: source, to: target)
        runtimeAvailability = switch status {
        case .installed: "installed"
        case .supported: "supported-not-installed"
        case .unsupported: "unsupported"
        @unknown default: "unknown"
        }
        return runtimeAvailability
    }

    public func translate(
        request: RussianTranscriptRequest,
        progress: @escaping @Sendable (RussianTranscriptTranslationUpdate) -> Void
    ) async throws -> RussianTranscriptResult {
        let requestKey = "\(request.videoID):\(request.sourceHash)"
        while activeRequestKey != nil {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(10))
        }
        activeRequestKey = requestKey
        defer {
            activeRequestKey = nil
            workQueue = nil
            configuration = nil
        }

        let startedAt = Date()
        let cachedRecord = await cache.load(request: request)
        var translations = cachedRecord?.translationsByIndex ?? [:]
        let cacheHit: RussianTranscriptCacheHit = if cachedRecord?.completed == true {
            .full
        } else if translations.isEmpty {
            .miss
        } else {
            .partial
        }
        let resumeCount = cacheHit == .partial
            ? (cachedRecord?.resumeCount ?? 0) + 1
            : (cachedRecord?.resumeCount ?? 0)
        var firstRussianLatency: TimeInterval? = translations.isEmpty ? nil : 0
        let cachedCues = RussianTranscriptPolicy.translatedCues(
            source: request.sourceCues,
            translationsByIndex: translations
        )
        emitTelemetry(
            request: request,
            translations: translations,
            playbackTime: request.playbackTime,
            firstRussianLatency: firstRussianLatency,
            cacheHit: cacheHit,
            resumeCount: resumeCount,
            progress: progress
        )
        if cachedRecord?.completed == true,
           cachedCues.count == request.sourceCues.count {
            progress(.translated(cues: cachedCues, stage: .translatingRemaining))
            return RussianTranscriptResult(cues: cachedCues, wasCached: true)
        }

        workQueue = RussianTranscriptWorkQueue(
            cues: request.sourceCues,
            completedIndices: Set(translations.keys),
            playbackTime: request.playbackTime
        )
        if !cachedCues.isEmpty {
            progress(.translated(cues: cachedCues, stage: .translatingCurrentFragment))
        }

        if ProcessInfo.processInfo.arguments.contains("--uitesting-russian-transcript-double") {
            runtimeAvailability = "deterministic-simulator-double"
            try await translateDeterministically(
                request: request,
                translations: &translations,
                startedAt: startedAt,
                firstRussianLatency: &firstRussianLatency,
                cacheHit: cacheHit,
                resumeCount: resumeCount,
                progress: progress
            )
        } else {
            let session = try await translationSession(progress: progress)
            try await translateUsingApple(
                request: request,
                session: session,
                translations: &translations,
                startedAt: startedAt,
                firstRussianLatency: &firstRussianLatency,
                cacheHit: cacheHit,
                resumeCount: resumeCount,
                progress: progress
            )
        }

        let result = RussianTranscriptPolicy.translatedCues(
            source: request.sourceCues,
            translationsByIndex: translations
        )
        guard result.count == request.sourceCues.count else {
            throw RussianTranscriptFailure.translationFailed
        }
        try await cache.store(
            request: request,
            translationsByIndex: translations,
            completed: true,
            resumeCount: resumeCount
        )
        return RussianTranscriptResult(cues: result, wasCached: false)
    }

    public func prepareTranslation(using session: TranslationSession) async {
        guard configuration != nil, !isPreparingSession else { return }
        isPreparingSession = true
        do {
            try await session.prepareTranslation()
            runtimeAvailability = "installed-after-system-prepare"
            isPreparingSession = false
            let continuation = sessionContinuation
            sessionContinuation = nil
            continuation?.resume(returning: session)
            while activeRequestKey != nil, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
            }
            configuration = nil
        } catch {
            configuration = nil
            isPreparingSession = false
            let continuation = sessionContinuation
            sessionContinuation = nil
            continuation?.resume(throwing: map(error))
        }
    }

    private func translationSession(
        progress: @escaping @Sendable (RussianTranscriptTranslationUpdate) -> Void
    ) async throws -> TranslationSession {
        let source = Locale.Language(identifier: "en")
        let target = Locale.Language(identifier: "ru")
        let status = await languageAvailability.status(from: source, to: target)
        switch status {
        case .installed:
            runtimeAvailability = "installed"
        case .supported:
            runtimeAvailability = "supported-not-installed"
            progress(.stage(.preparingAssets))
        case .unsupported:
            runtimeAvailability = "unsupported"
            throw RussianTranscriptFailure.unsupportedLanguagePair
        @unknown default:
            runtimeAvailability = "unknown"
            throw RussianTranscriptFailure.unsupportedLanguagePair
        }

        if #available(iOS 26.4, *) {
            configuration = TranslationSession.Configuration(
                source: source,
                target: target,
                preferredStrategy: .lowLatency
            )
        } else {
            configuration = TranslationSession.Configuration(source: source, target: target)
        }
        return try await waitForPreparedSession()
    }

    private func waitForPreparedSession() async throws -> TranslationSession {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                sessionContinuation = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self else { return }
                let continuation = self.sessionContinuation
                self.sessionContinuation = nil
                self.configuration = nil
                continuation?.resume(throwing: CancellationError())
            }
        }
    }

    private func translateUsingApple(
        request: RussianTranscriptRequest,
        session: TranslationSession,
        translations: inout [Int: String],
        startedAt: Date,
        firstRussianLatency: inout TimeInterval?,
        cacheHit: RussianTranscriptCacheHit,
        resumeCount: Int,
        progress: @escaping @Sendable (RussianTranscriptTranslationUpdate) -> Void
    ) async throws {
        do {
            try await session.prepareTranslation()
            while var queue = workQueue, !queue.isEmpty {
                try Task.checkCancellation()
                let batch = queue.nextBatch(size: currentBatchSize)
                let playbackTime = queue.playbackTime
                workQueue = queue
                guard !batch.isEmpty else { break }
                let stage = RussianTranscriptPolicy.stage(
                    for: batch,
                    cues: request.sourceCues,
                    playbackTime: playbackTime
                )
                progress(.stage(stage))
                let requests = batch.map { index in
                    TranslationSession.Request(
                        sourceText: request.sourceCues[index].text,
                        clientIdentifier: RussianTranscriptPolicy.stableClientIdentifier(
                            videoID: request.videoID,
                            sourceTrackID: request.sourceTrackID,
                            sourceHash: request.sourceHash,
                            cueIndex: index
                        )
                    )
                }
                let identifiers = Dictionary(uniqueKeysWithValues: batch.map {
                    (RussianTranscriptPolicy.stableClientIdentifier(
                        videoID: request.videoID,
                        sourceTrackID: request.sourceTrackID,
                        sourceHash: request.sourceHash,
                        cueIndex: $0
                    ), $0)
                })
                for try await response in session.translate(batch: requests) {
                    guard let index = RussianTranscriptPolicy.responseIndex(
                        clientIdentifier: response.clientIdentifier,
                        expectedIdentifiers: identifiers
                    ),
                          !response.targetText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        continue
                    }
                    translations[index] = response.targetText
                    if firstRussianLatency == nil {
                        firstRussianLatency = Date().timeIntervalSince(startedAt)
                    }
                    try await cache.store(
                        request: request,
                        translationsByIndex: translations,
                        completed: false,
                        resumeCount: resumeCount
                    )
                    publishProgress(
                        request: request,
                        translations: translations,
                        playbackTime: playbackTime,
                        stage: stage,
                        firstRussianLatency: firstRussianLatency,
                        cacheHit: cacheHit,
                        resumeCount: resumeCount,
                        progress: progress
                    )
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw map(error)
        }
    }

    private func translateDeterministically(
        request: RussianTranscriptRequest,
        translations: inout [Int: String],
        startedAt: Date,
        firstRussianLatency: inout TimeInterval?,
        cacheHit: RussianTranscriptCacheHit,
        resumeCount: Int,
        progress: @escaping @Sendable (RussianTranscriptTranslationUpdate) -> Void
    ) async throws {
        while var queue = workQueue, !queue.isEmpty {
            try Task.checkCancellation()
            let batch = queue.nextBatch(size: currentBatchSize)
            let playbackTime = queue.playbackTime
            workQueue = queue
            guard !batch.isEmpty else { break }
            let stage = RussianTranscriptPolicy.stage(
                for: batch,
                cues: request.sourceCues,
                playbackTime: playbackTime
            )
            progress(.stage(stage))
            for index in batch.reversed() {
                try await Task.sleep(for: .milliseconds(6))
                translations[index] = "Переведённая реплика \(index + 1)"
                if firstRussianLatency == nil {
                    firstRussianLatency = Date().timeIntervalSince(startedAt)
                }
                try await cache.store(
                    request: request,
                    translationsByIndex: translations,
                    completed: false,
                    resumeCount: resumeCount
                )
                publishProgress(
                    request: request,
                    translations: translations,
                    playbackTime: playbackTime,
                    stage: stage,
                    firstRussianLatency: firstRussianLatency,
                    cacheHit: cacheHit,
                    resumeCount: resumeCount,
                    progress: progress
                )
            }
        }
    }

    private var currentBatchSize: Int {
        switch ProcessInfo.processInfo.thermalState {
        case .serious, .critical: 3
        default: RussianTranscriptPolicy.batchSize
        }
    }

    private func publishProgress(
        request: RussianTranscriptRequest,
        translations: [Int: String],
        playbackTime: TimeInterval,
        stage: RussianTranscriptTranslationStage,
        firstRussianLatency: TimeInterval?,
        cacheHit: RussianTranscriptCacheHit,
        resumeCount: Int,
        progress: @escaping @Sendable (RussianTranscriptTranslationUpdate) -> Void
    ) {
        progress(.translated(
            cues: RussianTranscriptPolicy.translatedCues(
                source: request.sourceCues,
                translationsByIndex: translations
            ),
            stage: stage
        ))
        emitTelemetry(
            request: request,
            translations: translations,
            playbackTime: playbackTime,
            firstRussianLatency: firstRussianLatency,
            cacheHit: cacheHit,
            resumeCount: resumeCount,
            progress: progress
        )
    }

    private func emitTelemetry(
        request: RussianTranscriptRequest,
        translations: [Int: String],
        playbackTime: TimeInterval,
        firstRussianLatency: TimeInterval?,
        cacheHit: RussianTranscriptCacheHit,
        resumeCount: Int,
        progress: @escaping @Sendable (RussianTranscriptTranslationUpdate) -> Void
    ) {
        progress(.telemetry(RussianTranscriptTelemetry(
            timeToFirstRussian: firstRussianLatency,
            translatedAheadSeconds: RussianTranscriptPolicy.translatedAheadSeconds(
                source: request.sourceCues,
                translatedIndices: Set(translations.keys),
                playbackTime: playbackTime
            ),
            translatedCueCount: translations.count,
            totalCueCount: request.sourceCues.count,
            cacheHit: cacheHit,
            resumeCount: resumeCount
        )))
    }

    private func map(_ error: Error) -> RussianTranscriptFailure {
        if let failure = error as? RussianTranscriptFailure { return failure }
        if TranslationError.notInstalled ~= error {
            return .preparationDeclinedOrOffline
        }
        if TranslationError.unsupportedLanguagePairing ~= error
            || TranslationError.unsupportedSourceLanguage ~= error
            || TranslationError.unsupportedTargetLanguage ~= error {
            return .unsupportedLanguagePair
        }
        return .translationFailed
    }
}
#endif
