#if os(iOS)
import AVFoundation
import CryptoKit
import Foundation
@preconcurrency import Translation
import iPocketTubeCore
import os

@MainActor
final class LocalDubbingService {
    typealias TranscriptLoader = @MainActor @Sendable (
        LocalTranscriptRequest,
        @escaping @Sendable (LocalTranscriptProgress) -> Void
    ) async throws -> LocalTranscriptResult
    typealias ProgressHandler = @MainActor @Sendable (LocalDubbingProgressUpdate) -> Void

    private let transcriptLoader: TranscriptLoader
    private let cache: LocalDubbingCache
    private let supertonic: SupertonicSpeechSynthesizer
    private let appleVoice = AppleSpeechFileSynthesizer()
    private let languageAvailability = LanguageAvailability()
    private var translationSession: TranslationSession?

    init(
        transcriptLoader: @escaping TranscriptLoader,
        cache: LocalDubbingCache = LocalDubbingCache(),
        supertonic: SupertonicSpeechSynthesizer = SupertonicSpeechSynthesizer()
    ) {
        self.transcriptLoader = transcriptLoader
        self.cache = cache
        self.supertonic = supertonic
    }

    func cachedResult(videoID: String) async -> LocalDubbingCache.ResolvedResult? {
        await cache.load(videoID: videoID)
    }

    func hasResumableWork(videoID: String) async -> Bool {
        await cache.hasResumableWork(videoID: videoID)
    }

    func loadPlayback(videoID: String) async -> LocalDubbingPlaybackSnapshot? {
        await cache.loadPlayback(videoID: videoID)
    }

    func savePlayback(_ snapshot: LocalDubbingPlaybackSnapshot) async {
        try? await cache.savePlayback(snapshot)
    }

    func process(
        request: LocalDubbingRequest,
        progress: @escaping ProgressHandler
    ) async throws -> LocalDubbingCache.ResolvedResult {
        let ownershipToken = UUID()
        guard await LocalDubbingJobArbiter.shared.acquire(
            videoID: request.videoID,
            token: ownershipToken
        ) else {
            throw LocalDubbingFailure.jobAlreadyActive
        }
        do {
            let result = try await runOwnedProcess(request: request, progress: progress)
            await LocalDubbingJobArbiter.shared.release(
                videoID: request.videoID,
                token: ownershipToken
            )
            return result
        } catch {
            await LocalDubbingJobArbiter.shared.release(
                videoID: request.videoID,
                token: ownershipToken
            )
            throw error
        }
    }

    private func runOwnedProcess(
        request: LocalDubbingRequest,
        progress: @escaping ProgressHandler
    ) async throws -> LocalDubbingCache.ResolvedResult {
        guard FileManager.default.fileExists(atPath: request.sourceAudioURL.path) else {
            throw LocalDubbingFailure.audioUnavailable
        }
        guard Self.hasEnoughStorage() else { throw LocalDubbingFailure.insufficientStorage }
        if ProcessInfo.processInfo.thermalState == .critical {
            throw LocalDubbingFailure.thermalPressure
        }

        let compatibleWork = await cache.compatibleWork(videoID: request.videoID)
        let persistedOverride = compatibleWork?.sourceLanguageDecision.flatMap {
            $0.usedOverride ? $0.language.rawValue : nil
        }
        let effectiveRequest = LocalDubbingRequest(
            videoID: request.videoID,
            title: request.title,
            sourceAudioURL: request.sourceAudioURL,
            availableSourceCues: request.availableSourceCues,
            availableSourceOrigin: request.availableSourceOrigin,
            sourceCaptionLanguageCode: request.sourceCaptionLanguageCode,
            sourceLanguageOverride: request.sourceLanguageOverride ?? persistedOverride,
            maximumSourceDuration: request.maximumSourceDuration
        )
        let cacheIdentity = try Self.cacheIdentity(request: effectiveRequest)
        if let cached = await cache.load(
            videoID: request.videoID,
            cacheIdentity: cacheIdentity
        ) {
            if ProcessInfo.processInfo.arguments.contains("--uitesting-dubbing-auto-start") {
                print("AXRTUBE_DUBBING_SMOKE_CACHE_HIT disk")
            }
            progress(LocalDubbingProgressUpdate(stage: .ready, overallProgress: 1))
            return cached
        }

        let startedAt = Date()
        let startingThermal = ProcessInfo.processInfo.thermalState.rawValue
        var minimumAvailableMemory = Self.availableMemory()
        var peakResidentMemory = Self.peakResidentMemory()
        func sampleResources() {
            minimumAvailableMemory = min(minimumAvailableMemory, Self.availableMemory())
            peakResidentMemory = max(peakResidentMemory, Self.peakResidentMemory())
        }

        let workDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AxrTubeDubbing", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDirectory) }

        let storedManifest = await cache.loadWork(
            videoID: request.videoID,
            cacheIdentity: cacheIdentity,
            migrateUnknownLanguage: request.sourceLanguageOverride != nil
        )
        var manifest = storedManifest ?? LocalDubbingWorkManifest(
            cacheIdentity: cacheIdentity,
            videoID: request.videoID,
            title: request.title
        )
        if Self.smokeLoggingEnabled, let storedManifest {
            print("AXRTUBE_DUBBING_SMOKE_RESUME_MANIFEST phase=\(storedManifest.phase.rawValue) translations=\(storedManifest.translationsByIndex.count) segments=\(storedManifest.completedSegmentIndices.count)")
        }
        try await cache.saveWork(manifest)

        var source: (cues: [CaptionCue], origin: LocalDubbingTranscriptOrigin)
        var requiresASR = false
        if !manifest.sourceCues.isEmpty, let origin = manifest.transcriptOrigin {
            source = (manifest.sourceCues, origin)
        } else if let cues = LocalDubbingPolicy.usableSourceTranscript(
            cues: request.availableSourceCues
        ) {
            source = (
                Self.cues(cues, limitedTo: request.maximumSourceDuration),
                request.availableSourceOrigin ?? .youtubeCaptions
            )
        } else {
            requiresASR = true
            let requestedLanguage = LocalDubbingPolicy.sourceLanguage(
                for: effectiveRequest.sourceLanguageOverride
                    ?? effectiveRequest.sourceCaptionLanguageCode
            )
            guard requestedLanguage == .english || requestedLanguage == .russian else {
                throw LocalDubbingFailure.sourceLanguageChoiceRequired
            }
            let preliminaryPlan = LocalDubbingProgressPlan(
                requiresASR: true,
                requiresTranslation: requestedLanguage == .english
            )
            progress(Self.update(
                stage: .preparingAudio,
                plan: preliminaryPlan,
                phase: .preparingAudio,
                phaseProgress: 0
            ))
            let sourceAudioURL = try await Self.clippedSourceAudio(
                request.sourceAudioURL,
                maximumDuration: request.maximumSourceDuration,
                workDirectory: workDirectory
            )
            progress(Self.update(
                stage: .determiningLanguage,
                plan: preliminaryPlan,
                phase: .determiningLanguage,
                phaseProgress: 1
            ))
            progress(Self.update(
                stage: .preparingASR(progress: 0),
                plan: preliminaryPlan,
                phase: .preparingASR,
                phaseProgress: 0
            ))
            let transcript = try await transcriptLoader(
                LocalTranscriptRequest(
                    videoID: request.videoID,
                    audioURL: sourceAudioURL,
                    localeIdentifier: requestedLanguage == .russian ? "ru-RU" : "en-US"
                )
            ) { update in
                Task { @MainActor in
                    switch update {
                    case .preparingModel(let value):
                        progress(Self.update(
                            stage: .preparingASR(progress: value),
                            plan: preliminaryPlan,
                            phase: .preparingASR,
                            phaseProgress: value
                        ))
                    case .recognizing(let value):
                        progress(Self.update(
                            stage: .transcribing(progress: value),
                            plan: preliminaryPlan,
                            phase: .transcribing,
                            phaseProgress: value
                        ))
                    }
                }
            }
            let cues = CaptionTranscriptPolicy.normalizedCues(transcript.cues)
            guard !cues.isEmpty else { throw LocalDubbingFailure.sourceTranscriptUnavailable }
            source = (
                cues,
                transcript.engine == .parakeetTDTv2 ? .parakeet : .speechAnalyzer
            )
        }
        manifest.sourceCues = source.cues
        manifest.transcriptOrigin = source.origin
        let evidence = Self.detectedLanguage(in: source.cues)
        var languageDecision = LocalDubbingPolicy.languageDecision(
            metadataLanguageCode: request.sourceCaptionLanguageCode,
            overrideLanguageCode: effectiveRequest.sourceLanguageOverride,
            detectedLanguageCode: evidence.code,
            detectedConfidence: evidence.confidence
        )
        if languageDecision.language == .russian,
           !LocalDubbingPolicy.canBypassTranslation(
                cues: source.cues,
                decision: languageDecision
           ) {
            languageDecision = LocalDubbingLanguageDecision(
                language: .english,
                confidence: evidence.confidence,
                usedOverride: false,
                metadataLanguageCode: request.sourceCaptionLanguageCode,
                detectedLanguageCode: evidence.code
            )
            if Self.smokeLoggingEnabled {
                print("AXRTUBE_DUBBING_SMOKE_LANGUAGE_CORRECTED en")
            }
        }
        let plan = LocalDubbingProgressPlan(
            requiresASR: requiresASR,
            requiresTranslation: LocalDubbingPolicy.shouldTranslate(languageDecision)
        )
        if !requiresASR {
            progress(Self.update(
                stage: .preparingAudio,
                plan: plan,
                phase: .preparingAudio,
                phaseProgress: 1
            ))
            progress(Self.update(
                stage: .determiningLanguage,
                plan: plan,
                phase: .determiningLanguage,
                phaseProgress: 1
            ))
        }
        let previousLanguage = manifest.sourceLanguageDecision?.language
        if let previousLanguage,
           previousLanguage != .unknown,
           previousLanguage != languageDecision.language {
            manifest.translationsByIndex = [:]
            manifest.completedSegmentIndices = []
            manifest.voiceEngine = nil
            await cache.resetSegments(videoID: request.videoID)
        }
        manifest.sourceLanguageDecision = languageDecision
        guard languageDecision.language == .english || languageDecision.language == .russian else {
            try await cache.saveWork(manifest)
            throw LocalDubbingFailure.sourceLanguageChoiceRequired
        }
        manifest.translationBypassed = languageDecision.language.translationBypassed
        manifest.phase = languageDecision.language.translationBypassed ? .synthesis : .translation
        try await cache.saveWork(manifest)
        try Task.checkCancellation()
        sampleResources()

        let translatedCues: [CaptionCue]
        if !LocalDubbingPolicy.shouldTranslate(languageDecision) {
            translatedCues = source.cues
            manifest.translationsByIndex = Dictionary(
                uniqueKeysWithValues: source.cues.enumerated().map { ($0.offset, $0.element.text) }
            )
            manifest.phase = .synthesis
            try await cache.saveWork(manifest)
            if Self.smokeLoggingEnabled {
                print("AXRTUBE_DUBBING_SMOKE_TRANSLATION_BYPASS source=ru")
            }
        } else {
            progress(Self.update(
                stage: .preparingTranslation,
                plan: plan,
                phase: .translation,
                phaseProgress: 0
            ))
            translatedCues = try await translate(
                source.cues,
                manifest: &manifest,
                plan: plan,
                progress: progress
            )
        }
        guard translatedCues.count == source.cues.count, !translatedCues.isEmpty else {
            throw LocalDubbingFailure.translationFailed
        }
        try Task.checkCancellation()
        sampleResources()

        let voiceEngine: LocalDubbingVoiceEngine
        var modelCacheBytes: Int64 = 0
        if manifest.voiceEngine == .avSpeechSynthesizer {
            try await synthesizeWithAppleVoice(
                cues: translatedCues,
                manifest: &manifest,
                workDirectory: workDirectory,
                plan: plan,
                isRussianDirect: !LocalDubbingPolicy.shouldTranslate(languageDecision),
                progress: progress
            )
            voiceEngine = .avSpeechSynthesizer
            modelCacheBytes = await supertonic.cachedByteCount()
        } else {
            do {
                progress(Self.update(
                    stage: .preparingVoice(progress: 0),
                    plan: plan,
                    phase: .preparingVoice,
                    phaseProgress: 0
                ))
                modelCacheBytes = try await supertonic.prepare { value in
                    Task { @MainActor in
                        progress(Self.update(
                            stage: .preparingVoice(progress: value),
                            plan: plan,
                            phase: .preparingVoice,
                            phaseProgress: value
                        ))
                    }
                }
                manifest.voiceEngine = .supertonic3
                manifest.phase = .synthesis
                try await cache.saveWork(manifest)
                try await synthesizeWithSupertonic(
                    cues: translatedCues,
                    manifest: &manifest,
                    workDirectory: workDirectory,
                    plan: plan,
                    isRussianDirect: !LocalDubbingPolicy.shouldTranslate(languageDecision),
                    progress: progress
                )
                voiceEngine = .supertonic3
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                await cache.resetSegments(videoID: request.videoID)
                manifest.completedSegmentIndices = []
                manifest.voiceEngine = .avSpeechSynthesizer
                try await cache.saveWork(manifest)
                progress(Self.update(
                    stage: .preparingVoice(progress: 1),
                    plan: plan,
                    phase: .preparingVoice,
                    phaseProgress: 1
                ))
                try await synthesizeWithAppleVoice(
                    cues: translatedCues,
                    manifest: &manifest,
                    workDirectory: workDirectory,
                    plan: plan,
                    isRussianDirect: !LocalDubbingPolicy.shouldTranslate(languageDecision),
                    progress: progress
                )
                voiceEngine = .avSpeechSynthesizer
                modelCacheBytes = await supertonic.cachedByteCount()
            }
        }
        await supertonic.cleanup()
        try Task.checkCancellation()
        sampleResources()

        progress(Self.update(
            stage: .assembling(progress: 0),
            plan: plan,
            phase: .assembly,
            phaseProgress: 0
        ))
        manifest.phase = .assembly
        try await cache.saveWork(manifest)
        var segmentURLs: [URL] = []
        for index in translatedCues.indices {
            segmentURLs.append(await cache.segmentURL(index: index, videoID: request.videoID))
        }
        let temporaryM4A = try await Self.assembleM4A(
            cues: translatedCues,
            segmentURLs: segmentURLs,
            plan: plan,
            progress: progress
        )
        defer { try? FileManager.default.removeItem(at: temporaryM4A) }
        let outputBytes = Int64(
            (try? temporaryM4A.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        )
        guard outputBytes > 0 else { throw LocalDubbingFailure.exportFailed }
        sampleResources()
        progress(Self.update(
            stage: .validating,
            plan: plan,
            phase: .validation,
            phaseProgress: 0.25
        ))

        let safeTitle = TranscriptExportPolicy.safeFilename(request.title)
        let audioFilename = "\(safeTitle)-RU.m4a"
        let transcriptFilename = "\(safeTitle)-RU.txt"
        let document = TranscriptExportDocument(
            title: "\(request.title) (русская озвучка)",
            videoID: request.videoID,
            source: .russianDubbing,
            cues: translatedCues
        )
        let result = LocalDubbingResult(
            videoID: request.videoID,
            title: request.title,
            cues: translatedCues,
            transcriptOrigin: source.origin,
            sourceLanguage: languageDecision.language,
            translationBypassed: languageDecision.language.translationBypassed,
            cacheIdentity: cacheIdentity,
            voiceEngine: voiceEngine,
            audioFilename: audioFilename,
            transcriptFilename: transcriptFilename,
            metrics: LocalDubbingMetrics(
                wallTime: Date().timeIntervalSince(startedAt),
                minimumAvailableMemoryBytes: minimumAvailableMemory,
                peakResidentMemoryBytes: peakResidentMemory,
                modelCacheBytes: modelCacheBytes + Self.directorySize(
                    FileManager.default
                        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                        .appendingPathComponent("AxrTubeDubbing/Models/ParakeetTDTv2")
                ),
                outputBytes: outputBytes,
                startingThermalState: startingThermal,
                endingThermalState: ProcessInfo.processInfo.thermalState.rawValue
            )
        )
        let stored = try await cache.store(
            result: result,
            temporaryAudioURL: temporaryM4A,
            transcriptText: document.plainText
        )
        await cache.clearWork(videoID: request.videoID)
        progress(LocalDubbingProgressUpdate(stage: .ready, overallProgress: 1))
        return stored
    }

    func cancel() {
        translationSession?.cancel()
        translationSession = nil
        appleVoice.cancel()
    }

    func prepareTranslation(using session: TranslationSession) async throws {
        translationSession = session
        do {
            try await session.prepareTranslation()
            guard await session.isReady else {
                throw LocalDubbingFailure.translationPreparationFailed
            }
        } catch is CancellationError {
            translationSession = nil
            throw CancellationError()
        } catch {
            translationSession = nil
            throw LocalDubbingFailure.translationPreparationFailed
        }
    }

    func translationAvailabilityStatus() async -> LocalDubbingTranslationAvailability {
        let source = Locale.Language(identifier: "en")
        let target = Locale.Language(identifier: "ru")
        let status = await languageAvailability.status(from: source, to: target)
        let mapped: LocalDubbingTranslationAvailability = switch status {
        case .installed: .installed
        case .supported: .supported
        case .unsupported: .unsupported
        @unknown default: .unsupported
        }
        if Self.smokeLoggingEnabled {
            print("AXRTUBE_DUBBING_TRANSLATION_AVAILABILITY \(String(describing: mapped))")
        }
        return mapped
    }

    private func translate(
        _ cues: [CaptionCue],
        manifest: inout LocalDubbingWorkManifest,
        plan: LocalDubbingProgressPlan,
        progress: @escaping ProgressHandler
    ) async throws -> [CaptionCue] {
        let source = Locale.Language(identifier: "en")
        let target = Locale.Language(identifier: "ru")
        let session: TranslationSession
        if let prepared = translationSession, await prepared.isReady {
            session = prepared
        } else {
            translationSession = nil
            switch LocalDubbingTranslationPolicy.action(
                for: await translationAvailabilityStatus()
            ) {
            case .translate:
                session = TranslationSession(installedSource: source, target: target)
            case .prepare:
                throw LocalDubbingFailure.translationPreparationRequired
            case .failUnsupported:
                throw LocalDubbingFailure.translationPairUnsupported
            }
        }
        translationSession = session
        do {
            try await session.prepareTranslation()
            var translated = manifest.translationsByIndex.reduce(into: [String: String]()) {
                $0[String($1.key)] = $1.value
            }
            for (index, cue) in cues.enumerated() {
                try Task.checkCancellation()
                if let existing = manifest.translationsByIndex[index],
                   !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    translated[String(index)] = existing
                    let value = Double(index + 1) / Double(max(1, cues.count))
                    progress(Self.update(
                        stage: .translating(progress: value),
                        plan: plan,
                        phase: .translation,
                        phaseProgress: value
                    ))
                    continue
                }
                let response = try await session.translate(cue.text)
                translated[String(index)] = response.targetText
                manifest.translationsByIndex[index] = response.targetText
                manifest.phase = .translation
                try await cache.saveWork(manifest)
                let value = Double(index + 1) / Double(max(1, cues.count))
                progress(Self.update(
                    stage: .translating(progress: value),
                    plan: plan,
                    phase: .translation,
                    phaseProgress: value
                ))
            }
            return LocalDubbingPolicy.translatedCues(
                source: cues,
                translationsByIdentifier: translated
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let failure as LocalDubbingFailure {
            throw failure
        } catch {
            if TranslationError.notInstalled ~= error {
                throw LocalDubbingFailure.translationPreparationRequired
            }
            if TranslationError.unsupportedLanguagePairing ~= error
                || TranslationError.unsupportedSourceLanguage ~= error
                || TranslationError.unsupportedTargetLanguage ~= error {
                throw LocalDubbingFailure.translationPairUnsupported
            }
            throw LocalDubbingFailure.translationFailed
        }
    }

    private func synthesizeWithSupertonic(
        cues: [CaptionCue],
        manifest: inout LocalDubbingWorkManifest,
        workDirectory: URL,
        plan: LocalDubbingProgressPlan,
        isRussianDirect: Bool,
        progress: @escaping ProgressHandler
    ) async throws {
        let valid = await cache.validSegmentIndices(videoID: manifest.videoID, total: cues.count)
        manifest.completedSegmentIndices.formIntersection(valid)
        if Self.smokeLoggingEnabled, !manifest.completedSegmentIndices.isEmpty {
            print("AXRTUBE_DUBBING_SMOKE_RESUME_SEGMENTS completed=\(manifest.completedSegmentIndices.count) total=\(cues.count)")
        }
        try await cache.saveWork(manifest)
        let pending = LocalDubbingPolicy.pendingSegmentIndices(
            total: cues.count,
            completed: manifest.completedSegmentIndices,
            valid: { valid.contains($0) }
        )
        let resumedFrom = manifest.completedSegmentIndices.count
        let initialFraction = LocalDubbingPolicy.weightedSegmentCompletion(
            cues: cues,
            completed: manifest.completedSegmentIndices
        )
        progress(Self.update(
            stage: .synthesizing(progress: initialFraction),
            plan: plan,
            phase: .synthesis,
            phaseProgress: initialFraction,
            completedSegments: resumedFrom,
            totalSegments: cues.count,
            resumedFromSegments: resumedFrom,
            isRussianDirect: isRussianDirect
        ))
        for index in pending {
            try Task.checkCancellation()
            if ProcessInfo.processInfo.thermalState == .critical {
                throw LocalDubbingFailure.thermalPressure
            }
            let cue = cues[index]
            let destination = workDirectory
                .appendingPathComponent(String(format: "segment-%05d.wav.new", index))
            try? FileManager.default.removeItem(at: destination)
            _ = try await supertonic.synthesize(
                text: cue.text,
                destination: destination,
                speed: LocalDubbingPolicy.playbackRate
            )
            _ = try await cache.installSegment(
                stagingURL: destination,
                index: index,
                videoID: manifest.videoID
            )
            manifest.completedSegmentIndices.insert(index)
            manifest.phase = .synthesis
            try await cache.saveWork(manifest)
            let fraction = LocalDubbingPolicy.weightedSegmentCompletion(
                cues: cues,
                completed: manifest.completedSegmentIndices
            )
            progress(Self.update(
                stage: .synthesizing(progress: fraction),
                plan: plan,
                phase: .synthesis,
                phaseProgress: fraction,
                completedSegments: manifest.completedSegmentIndices.count,
                totalSegments: cues.count,
                resumedFromSegments: resumedFrom,
                isRussianDirect: isRussianDirect
            ))
            if ProcessInfo.processInfo.thermalState == .serious {
                try await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    private func synthesizeWithAppleVoice(
        cues: [CaptionCue],
        manifest: inout LocalDubbingWorkManifest,
        workDirectory: URL,
        plan: LocalDubbingProgressPlan,
        isRussianDirect: Bool,
        progress: @escaping ProgressHandler
    ) async throws {
        let valid = await cache.validSegmentIndices(videoID: manifest.videoID, total: cues.count)
        manifest.completedSegmentIndices.formIntersection(valid)
        if Self.smokeLoggingEnabled, !manifest.completedSegmentIndices.isEmpty {
            print("AXRTUBE_DUBBING_SMOKE_RESUME_SEGMENTS completed=\(manifest.completedSegmentIndices.count) total=\(cues.count)")
        }
        try await cache.saveWork(manifest)
        let pending = LocalDubbingPolicy.pendingSegmentIndices(
            total: cues.count,
            completed: manifest.completedSegmentIndices,
            valid: { valid.contains($0) }
        )
        let resumedFrom = manifest.completedSegmentIndices.count
        let initialFraction = LocalDubbingPolicy.weightedSegmentCompletion(
            cues: cues,
            completed: manifest.completedSegmentIndices
        )
        progress(Self.update(
            stage: .synthesizing(progress: initialFraction),
            plan: plan,
            phase: .synthesis,
            phaseProgress: initialFraction,
            completedSegments: resumedFrom,
            totalSegments: cues.count,
            resumedFromSegments: resumedFrom,
            isRussianDirect: isRussianDirect
        ))
        for index in pending {
            try Task.checkCancellation()
            let cue = cues[index]
            let destination = workDirectory
                .appendingPathComponent(String(format: "segment-%05d.wav.new", index))
            try? FileManager.default.removeItem(at: destination)
            try await appleVoice.synthesize(text: cue.text, destination: destination)
            _ = try await cache.installSegment(
                stagingURL: destination,
                index: index,
                videoID: manifest.videoID
            )
            manifest.completedSegmentIndices.insert(index)
            manifest.phase = .synthesis
            try await cache.saveWork(manifest)
            let fraction = LocalDubbingPolicy.weightedSegmentCompletion(
                cues: cues,
                completed: manifest.completedSegmentIndices
            )
            progress(Self.update(
                stage: .synthesizing(progress: fraction),
                plan: plan,
                phase: .synthesis,
                phaseProgress: fraction,
                completedSegments: manifest.completedSegmentIndices.count,
                totalSegments: cues.count,
                resumedFromSegments: resumedFrom,
                isRussianDirect: isRussianDirect
            ))
        }
    }

    nonisolated private static func assembleM4A(
        cues: [CaptionCue],
        segmentURLs: [URL],
        plan: LocalDubbingProgressPlan,
        progress: @escaping ProgressHandler
    ) async throws -> URL {
        guard segmentURLs.count == cues.count else { throw LocalDubbingFailure.synthesisFailed }
        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else { throw LocalDubbingFailure.exportFailed }

        var previousSegmentEnd: TimeInterval = 0
        for (index, cue) in cues.enumerated() {
            try Task.checkCancellation()
            let segmentURL = segmentURLs[index]
            let asset = AVURLAsset(url: segmentURL)
            guard let sourceTrack = try await asset.loadTracks(withMediaType: .audio).first else {
                throw LocalDubbingFailure.synthesisFailed
            }
            let naturalDuration = try await asset.load(.duration)
            let naturalSeconds = naturalDuration.seconds
            guard naturalSeconds.isFinite, naturalSeconds > 0 else {
                throw LocalDubbingFailure.synthesisFailed
            }
            let scheduledStart = LocalDubbingPolicy.scheduledStart(
                cueStart: cue.startTime,
                previousSegmentEnd: previousSegmentEnd
            )
            let insertionStart = CMTime(seconds: scheduledStart, preferredTimescale: 600)
            let sourceRange = CMTimeRange(start: .zero, duration: naturalDuration)
            try track.insertTimeRange(sourceRange, of: sourceTrack, at: insertionStart)
            previousSegmentEnd = scheduledStart + naturalSeconds
            let value = Double(index + 1) / Double(cues.count + 1)
            await progress(update(
                stage: .assembling(progress: value),
                plan: plan,
                phase: .assembly,
                phaseProgress: value
            ))
        }

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("AxrTube-RU-\(UUID().uuidString).m4a")
        guard let exporter = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetAppleM4A
        ) else { throw LocalDubbingFailure.exportFailed }
        exporter.outputURL = destination
        exporter.outputFileType = .m4a
        await exporter.export()
        if let error = exporter.error {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        await progress(update(
            stage: .assembling(progress: 1),
            plan: plan,
            phase: .assembly,
            phaseProgress: 1
        ))
        return destination
    }

    nonisolated private static func update(
        stage: LocalDubbingStage,
        plan: LocalDubbingProgressPlan,
        phase: LocalDubbingProgressPhase,
        phaseProgress: Double,
        completedSegments: Int? = nil,
        totalSegments: Int? = nil,
        resumedFromSegments: Int = 0,
        isRussianDirect: Bool = false
    ) -> LocalDubbingProgressUpdate {
        LocalDubbingProgressUpdate(
            stage: stage,
            overallProgress: plan.overallProgress(
                phase: phase,
                phaseProgress: phaseProgress
            ),
            completedSegments: completedSegments,
            totalSegments: totalSegments,
            resumedFromSegments: resumedFromSegments,
            isRussianDirect: isRussianDirect
        )
    }

    nonisolated private static func clippedSourceAudio(
        _ sourceURL: URL,
        maximumDuration: TimeInterval?,
        workDirectory: URL
    ) async throws -> URL {
        guard let maximumDuration, maximumDuration > 0 else { return sourceURL }
        let asset = AVURLAsset(url: sourceURL)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > maximumDuration else { return sourceURL }
        let destination = workDirectory.appendingPathComponent("source-smoke.m4a")
        guard let exporter = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetAppleM4A
        ) else { throw LocalDubbingFailure.exportFailed }
        exporter.timeRange = CMTimeRange(
            start: .zero,
            duration: CMTime(seconds: maximumDuration, preferredTimescale: 600)
        )
        try await exporter.export(to: destination, as: .m4a)
        return destination
    }

    nonisolated private static func cues(
        _ cues: [CaptionCue],
        limitedTo maximumDuration: TimeInterval?
    ) -> [CaptionCue] {
        guard let maximumDuration else { return cues }
        return cues.compactMap { cue in
            guard cue.startTime < maximumDuration else { return nil }
            return CaptionCue(
                startTime: cue.startTime,
                endTime: min(cue.endTime, maximumDuration),
                text: cue.text
            )
        }
    }

    nonisolated static func cacheIdentity(request: LocalDubbingRequest) throws -> String {
        let payload = try LocalDubbingPolicy.cacheIdentityPayload(for: request)
        return SHA256.hash(data: payload)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    nonisolated private static func detectedLanguage(
        in cues: [CaptionCue]
    ) -> (code: String?, confidence: Double) {
        let evidence = LocalDubbingPolicy.scriptLanguageEvidence(in: cues)
        return (evidence.languageCode, evidence.confidence)
    }

    nonisolated private static func hasEnoughStorage() -> Bool {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let capacity = try? documents.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        ).volumeAvailableCapacityForImportantUsage
        return (capacity ?? Int64.max) >= LocalDubbingPolicy.minimumFreeBytes
    }

    nonisolated private static func availableMemory() -> UInt64 {
        UInt64(os_proc_available_memory())
    }

    nonisolated private static func peakResidentMemory() -> UInt64 {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        return UInt64(max(0, usage.ru_maxrss))
    }

    nonisolated private static func directorySize(_ directory: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]
        ) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }

    nonisolated private static var smokeLoggingEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains("--uitesting-dubbing-auto-start")
    }
}

@MainActor
private final class AppleSpeechFileSynthesizer {
    private var activeSynthesizer: AVSpeechSynthesizer?

    func synthesize(text: String, destination: URL) async throws {
        try? FileManager.default.removeItem(at: destination)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = Self.bestRussianVoice()
        utterance.rate = 0.48
        utterance.pitchMultiplier = 0.98
        utterance.preUtteranceDelay = 0.02
        utterance.postUtteranceDelay = 0.04
        let synthesizer = AVSpeechSynthesizer()
        synthesizer.usesApplicationAudioSession = false
        activeSynthesizer = synthesizer

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                var outputFile: AVAudioFile?
                var finished = false
                synthesizer.write(utterance) { buffer in
                    guard !finished else { return }
                    guard let pcm = buffer as? AVAudioPCMBuffer else {
                        finished = true
                        continuation.resume(throwing: LocalDubbingFailure.synthesisFailed)
                        return
                    }
                    if pcm.frameLength == 0 {
                        finished = true
                        continuation.resume()
                        return
                    }
                    do {
                        if outputFile == nil {
                            outputFile = try AVAudioFile(
                                forWriting: destination,
                                settings: pcm.format.settings,
                                commonFormat: pcm.format.commonFormat,
                                interleaved: pcm.format.isInterleaved
                            )
                        }
                        try outputFile?.write(from: pcm)
                    } catch {
                        finished = true
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel() }
        }
        activeSynthesizer = nil
    }

    func cancel() {
        activeSynthesizer?.stopSpeaking(at: .immediate)
        activeSynthesizer = nil
    }

    private static func bestRussianVoice() -> AVSpeechSynthesisVoice? {
        let russian = AVSpeechSynthesisVoice.speechVoices().filter {
            $0.language.lowercased().hasPrefix("ru")
        }
        return russian.max { lhs, rhs in lhs.quality.rawValue < rhs.quality.rawValue }
            ?? AVSpeechSynthesisVoice(language: "ru-RU")
    }
}
#endif
