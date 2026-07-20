#if os(iOS)
import AVFoundation
import CoreMedia
import FluidAudio
import Foundation
import Speech
import iPocketTubeCore

@MainActor
final class LocalSpeechTranscriptionService {
    private let cache: LocalTranscriptCache
    private var activeAnalyzer: SpeechAnalyzer?

    init(cache: LocalTranscriptCache = LocalTranscriptCache()) {
        self.cache = cache
    }

    func transcribe(
        request: LocalTranscriptRequest,
        progress: @escaping @Sendable (LocalTranscriptProgress) -> Void
    ) async throws -> LocalTranscriptResult {
        if let cached = await cache.load(videoID: request.videoID) {
            progress(.recognizing(1))
            return cached
        }
        guard FileManager.default.fileExists(atPath: request.audioURL.path) else {
            throw LocalTranscriptFailure.audioUnavailable
        }
        try Task.checkCancellation()

        let requestedLocale = Locale(identifier: request.localeIdentifier)
        let output = try await withTaskCancellationHandler {
            if requestedLocale.language.languageCode?.identifier == "en" {
                do {
                    return try await transcribeWithParakeet(
                        audioURL: request.audioURL,
                        progress: progress
                    )
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // The system analyzer is the offline fallback when Parakeet
                    // assets are unavailable, corrupt, or cannot compile on device.
                }
            }
            if SpeechTranscriber.isAvailable,
               let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requestedLocale) {
                return (
                    try await transcribeWithSpeechTranscriber(
                        audioURL: request.audioURL,
                        locale: locale,
                        progress: progress
                    ),
                    LocalTranscriptionEngine.speechAnalyzer
                )
            }
            if let locale = await DictationTranscriber.supportedLocale(equivalentTo: requestedLocale) {
                return (
                    try await transcribeWithDictationTranscriber(
                        audioURL: request.audioURL,
                        locale: locale,
                        progress: progress
                    ),
                    LocalTranscriptionEngine.speechAnalyzer
                )
            }
            throw LocalTranscriptFailure.onDeviceRecognitionUnavailable
        } onCancel: {
            Task { @MainActor [weak self] in
                if let analyzer = self?.activeAnalyzer {
                    await analyzer.cancelAndFinishNow()
                }
                self?.activeAnalyzer = nil
            }
        }

        try Task.checkCancellation()
        let cues = LocalSpeechCuePolicy.cues(from: output.0)
        guard !cues.isEmpty else { throw LocalTranscriptFailure.recognitionFailed }
        try await cache.store(
            videoID: request.videoID,
            localeIdentifier: request.localeIdentifier,
            engine: output.1,
            cues: cues
        )
        progress(.recognizing(1))
        return LocalTranscriptResult(
            cues: cues,
            localeIdentifier: request.localeIdentifier,
            wasCached: false,
            engine: output.1
        )
    }

    private func transcribeWithParakeet(
        audioURL: URL,
        progress: @escaping @Sendable (LocalTranscriptProgress) -> Void
    ) async throws -> ([LocalSpeechSegment], LocalTranscriptionEngine) {
        let modelDirectory = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AxrTubeDubbing", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent("ParakeetTDTv2", isDirectory: true)
        let models = try await AsrModels.downloadAndLoad(
            to: modelDirectory,
            version: .v2,
            encoderPrecision: .int8,
            progressHandler: { update in
                progress(.preparingModel(min(1, max(0, update.fractionCompleted))))
            }
        )
        try Task.checkCancellation()
        let config = ASRConfig(
            tdtConfig: TdtConfig(blankId: AsrModelVersion.v2.blankId),
            encoderHiddenSize: AsrModelVersion.v2.encoderHiddenSize,
            parallelChunkConcurrency: 1,
            streamingEnabled: true,
            melChunkContext: true
        )
        let manager = AsrManager(config: config, models: models)
        let monitor = Task {
            let stream = await manager.transcriptionProgressStream
            do {
                for try await value in stream {
                    progress(.recognizing(min(0.99, max(0, value))))
                }
            } catch {
                // The transcription call below remains the authoritative error.
            }
        }
        defer {
            monitor.cancel()
            Task { await manager.cleanup() }
        }
        var decoderState = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let result = try await manager.transcribe(audioURL, decoderState: &decoderState)
        try Task.checkCancellation()
        let wordTimings = buildWordTimings(from: result.tokenTimings ?? [])
        let segments: [LocalSpeechSegment]
        if wordTimings.isEmpty {
            segments = [LocalSpeechSegment(
                startTime: 0,
                duration: max(0.1, result.duration),
                text: result.text
            )]
        } else {
            segments = wordTimings.map {
                LocalSpeechSegment(
                    startTime: $0.startTime,
                    duration: max(0.1, $0.endTime - $0.startTime),
                    text: $0.word
                )
            }
        }
        progress(.recognizing(1))
        return (segments, .parakeetTDTv2)
    }

    private func transcribeWithSpeechTranscriber(
        audioURL: URL,
        locale: Locale,
        progress: @escaping @Sendable (LocalTranscriptProgress) -> Void
    ) async throws -> [LocalSpeechSegment] {
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange]
        )
        try await ensureAssets(for: [transcriber], locale: locale, progress: progress)
        let file = try AVAudioFile(forReading: audioURL)
        let duration = file.length > 0 && file.fileFormat.sampleRate > 0
            ? Double(file.length) / file.fileFormat.sampleRate
            : 0
        let analyzer = SpeechAnalyzer(
            modules: [transcriber],
            options: .init(priority: .utility, modelRetention: .whileInUse)
        )
        activeAnalyzer = analyzer
        defer { activeAnalyzer = nil }
        async let collected = collectSpeechResults(
            from: transcriber,
            duration: duration,
            progress: progress
        )
        try await analyze(file: file, with: analyzer)
        return try await collected
    }

    private func transcribeWithDictationTranscriber(
        audioURL: URL,
        locale: Locale,
        progress: @escaping @Sendable (LocalTranscriptProgress) -> Void
    ) async throws -> [LocalSpeechSegment] {
        let transcriber = DictationTranscriber(locale: locale, preset: .timeIndexedLongDictation)
        try await ensureAssets(for: [transcriber], locale: locale, progress: progress)
        let file = try AVAudioFile(forReading: audioURL)
        let duration = file.length > 0 && file.fileFormat.sampleRate > 0
            ? Double(file.length) / file.fileFormat.sampleRate
            : 0
        let analyzer = SpeechAnalyzer(
            modules: [transcriber],
            options: .init(priority: .utility, modelRetention: .whileInUse)
        )
        activeAnalyzer = analyzer
        defer { activeAnalyzer = nil }
        async let collected = collectDictationResults(
            from: transcriber,
            duration: duration,
            progress: progress
        )
        try await analyze(file: file, with: analyzer)
        return try await collected
    }

    private func ensureAssets(
        for modules: [any SpeechModule],
        locale: Locale,
        progress: @escaping @Sendable (LocalTranscriptProgress) -> Void
    ) async throws {
        _ = try? await AssetInventory.reserve(locale: locale)
        let status = await AssetInventory.status(forModules: modules)
        guard status != .unsupported else {
            throw LocalTranscriptFailure.onDeviceRecognitionUnavailable
        }
        guard status != .installed else {
            progress(.preparingModel(1))
            return
        }
        guard let installation = try await AssetInventory.assetInstallationRequest(
            supporting: modules
        ) else {
            progress(.preparingModel(1))
            return
        }
        let monitor = Task {
            while !Task.isCancelled {
                progress(.preparingModel(min(1, max(0, installation.progress.fractionCompleted))))
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
        defer { monitor.cancel() }
        try await installation.downloadAndInstall()
        progress(.preparingModel(1))
    }

    private func analyze(file: AVAudioFile, with analyzer: SpeechAnalyzer) async throws {
        if let lastSample = try await analyzer.analyzeSequence(from: file) {
            try await analyzer.finalizeAndFinish(through: lastSample)
        } else {
            await analyzer.cancelAndFinishNow()
        }
    }

    private func collectSpeechResults(
        from transcriber: SpeechTranscriber,
        duration: TimeInterval,
        progress: @escaping @Sendable (LocalTranscriptProgress) -> Void
    ) async throws -> [LocalSpeechSegment] {
        var segments: [LocalSpeechSegment] = []
        for try await result in transcriber.results where result.isFinal {
            let segment = localSegment(
                text: String(result.text.characters),
                range: result.range
            )
            if let segment { segments.append(segment) }
            reportAnalysisProgress(range: result.range, duration: duration, progress: progress)
        }
        return segments
    }

    private func collectDictationResults(
        from transcriber: DictationTranscriber,
        duration: TimeInterval,
        progress: @escaping @Sendable (LocalTranscriptProgress) -> Void
    ) async throws -> [LocalSpeechSegment] {
        var segments: [LocalSpeechSegment] = []
        for try await result in transcriber.results where result.isFinal {
            let segment = localSegment(
                text: String(result.text.characters),
                range: result.range
            )
            if let segment { segments.append(segment) }
            reportAnalysisProgress(range: result.range, duration: duration, progress: progress)
        }
        return segments
    }

    private func localSegment(text: String, range: CMTimeRange) -> LocalSpeechSegment? {
        let start = range.start.seconds
        let duration = range.duration.seconds
        guard start.isFinite, duration.isFinite, duration >= 0 else { return nil }
        return LocalSpeechSegment(
            startTime: max(0, start),
            duration: max(0.1, duration),
            text: text
        )
    }

    private func reportAnalysisProgress(
        range: CMTimeRange,
        duration: TimeInterval,
        progress: @escaping @Sendable (LocalTranscriptProgress) -> Void
    ) {
        guard duration > 0 else { return }
        let analyzed = range.end.seconds
        guard analyzed.isFinite else { return }
        progress(.recognizing(min(0.99, max(0, analyzed / duration))))
    }
}
#endif
