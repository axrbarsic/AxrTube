import Foundation
import Testing
@testable import iPocketTube
@testable import iPocketTubeCore

@Suite("Local Russian dubbing policy")
struct LocalDubbingTests {
    private let sourceCues = [
        CaptionCue(startTime: 0.5, endTime: 2.0, text: "Hello there"),
        CaptionCue(startTime: 2.4, endTime: 4.1, text: "How are you?"),
    ]

    @Test("English YouTube cues are reused without ASR")
    func englishCaptionsHavePriority() {
        #expect(LocalDubbingPolicy.usableEnglishCaptions(
            cues: sourceCues,
            languageCode: "en-US"
        ) == sourceCues)
        #expect(LocalDubbingPolicy.usableEnglishCaptions(
            cues: sourceCues,
            languageCode: "ru"
        ) == nil)
    }

    @Test("Russian transcript bypasses translator")
    func russianTranscriptBypassesTranslator() {
        let decision = LocalDubbingPolicy.languageDecision(
            metadataLanguageCode: "ru-RU",
            overrideLanguageCode: nil,
            detectedLanguageCode: "ru",
            detectedConfidence: 0.98
        )
        #expect(decision.language == .russian)
        #expect(decision.language.translationBypassed)
        #expect(!LocalDubbingPolicy.shouldTranslate(decision))
        #expect(LocalDubbingPolicy.usableSourceCaptions(
            cues: sourceCues,
            languageCode: "ru"
        ) == sourceCues)
    }

    @Test("Strong cue evidence wins over stale metadata or override")
    func mixedOrUnknownLanguagePolicy() {
        let conflict = LocalDubbingPolicy.languageDecision(
            metadataLanguageCode: "en",
            overrideLanguageCode: nil,
            detectedLanguageCode: "ru",
            detectedConfidence: 0.97
        )
        #expect(conflict.language == .russian)
        #expect(!conflict.usedOverride)

        let uncertain = LocalDubbingPolicy.languageDecision(
            metadataLanguageCode: nil,
            overrideLanguageCode: nil,
            detectedLanguageCode: "ru",
            detectedConfidence: 0.6
        )
        #expect(uncertain.language == .unknown)

        let override = LocalDubbingPolicy.languageDecision(
            metadataLanguageCode: "en",
            overrideLanguageCode: "ru",
            detectedLanguageCode: "en",
            detectedConfidence: 0.99
        )
        #expect(override.language == .english)
        #expect(!override.usedOverride)
        #expect(LocalDubbingPolicy.shouldTranslate(override))
    }

    @Test("Full cue sample distinguishes English, Russian, mixed, and short text")
    func fullCueLanguageEvidence() {
        let english = (0..<221).map {
            CaptionCue(startTime: Double($0), endTime: Double($0 + 1), text: "This is a clearly English transcript fragment with enough letters")
        }
        let russian = (0..<40).map {
            CaptionCue(startTime: Double($0), endTime: Double($0 + 1), text: "Это явно русская реплика с достаточным количеством букв для проверки")
        }
        let mixed = (0..<20).map {
            CaptionCue(startTime: Double($0), endTime: Double($0 + 1), text: "English текст English текст")
        }
        #expect(LocalDubbingPolicy.scriptLanguageEvidence(in: english).languageCode == "en")
        #expect(LocalDubbingPolicy.scriptLanguageEvidence(in: russian).languageCode == "ru")
        #expect(LocalDubbingPolicy.scriptLanguageEvidence(in: mixed).languageCode == nil)
        #expect(LocalDubbingPolicy.scriptLanguageEvidence(in: sourceCues).languageCode == nil)
        let evidence = LocalDubbingPolicy.scriptLanguageEvidence(in: english)
        let corrected = LocalDubbingPolicy.languageDecision(
            metadataLanguageCode: nil,
            overrideLanguageCode: "ru",
            detectedLanguageCode: evidence.languageCode,
            detectedConfidence: evidence.confidence
        )
        #expect(corrected.language == .english)
        #expect(LocalDubbingPolicy.shouldTranslate(corrected))
    }

    @Test("Reliable RU and EN metadata resolves an insufficient cue sample")
    func metadataLanguageFallback() {
        let russian = LocalDubbingPolicy.languageDecision(
            metadataLanguageCode: "ru-RU",
            overrideLanguageCode: nil,
            detectedLanguageCode: nil,
            detectedConfidence: 0
        )
        let english = LocalDubbingPolicy.languageDecision(
            metadataLanguageCode: "en-US",
            overrideLanguageCode: nil,
            detectedLanguageCode: nil,
            detectedConfidence: 0
        )
        #expect(russian.language == .russian)
        #expect(english.language == .english)
    }

    @Test("Strong content evidence protects the Russian TTS preflight")
    func russianBypassPreflight() {
        let english = (0..<12).map {
            CaptionCue(startTime: Double($0), endTime: Double($0 + 1), text: "Strong English evidence must be translated before Russian voice synthesis")
        }
        let staleRussian = LocalDubbingLanguageDecision(
            language: .russian,
            confidence: 1,
            usedOverride: true,
            metadataLanguageCode: nil,
            detectedLanguageCode: "en"
        )
        #expect(!LocalDubbingPolicy.canBypassTranslation(cues: english, decision: staleRussian))
    }

    @Test("Translation availability distinguishes installed, missing, and unsupported pairs")
    func translationAvailabilityLifecycle() {
        #expect(LocalDubbingTranslationPolicy.action(for: .installed) == .translate)
        #expect(LocalDubbingTranslationPolicy.action(for: .supported) == .prepare)
        #expect(LocalDubbingTranslationPolicy.action(for: .unsupported) == .failUnsupported)
    }

    @Test("Translation preparation admits only one active system request")
    func singleTranslationPreparationRequest() {
        #expect(LocalDubbingTranslationPolicy.shouldBeginPreparation(
            isPreparing: false,
            hasConfiguration: true
        ))
        #expect(!LocalDubbingTranslationPolicy.shouldBeginPreparation(
            isPreparing: true,
            hasConfiguration: true
        ))
        #expect(!LocalDubbingTranslationPolicy.shouldBeginPreparation(
            isPreparing: false,
            hasConfiguration: false
        ))
    }

    @Test("Per-video job lease rejects duplicate owners and stale release")
    func singleDubbingJobOwner() async {
        let arbiter = LocalDubbingJobArbiter()
        let first = UUID()
        let second = UUID()
        #expect(await arbiter.acquire(videoID: "video", token: first))
        #expect(!(await arbiter.acquire(videoID: "video", token: second)))
        await arbiter.release(videoID: "video", token: second)
        #expect(await arbiter.isOwned(videoID: "video"))
        await arbiter.release(videoID: "video", token: first)
        #expect(!(await arbiter.isOwned(videoID: "video")))
        #expect(await arbiter.acquire(videoID: "video", token: second))
    }

    @Test("Missing translation assets use one indeterminate progress owner")
    func translationPreparationPresentation() {
        #expect(LocalDubbingPresentationPolicy.usesIndeterminateProgress(
            stage: .preparingTranslationAssets
        ))
        #expect(LocalDubbingPresentationPolicy.visibleProgressIndicatorCount(
            stage: .preparingTranslationAssets
        ) == 1)
        #expect(LocalDubbingPresentationPolicy.showsTranslationRetry(
            failure: .translationPreparationFailed
        ))
        #expect(!LocalDubbingPresentationPolicy.showsTranslationRetry(
            failure: .translationPairUnsupported
        ))
        #expect(LocalDubbingFailure.translationPairUnsupported.userMessage
            != LocalDubbingFailure.translationPreparationFailed.userMessage)
    }

    @Test("Translation route copy keeps source and Russian result unambiguous")
    func translationRouteCopy() {
        let preparing = LocalDubbingProgressUpdate(
            stage: .preparingTranslationAssets,
            overallProgress: 0.1
        )
        let translating = LocalDubbingProgressUpdate(
            stage: .translating(progress: 0.2),
            overallProgress: 0.2
        )
        #expect(preparing.statusText == "Подготавливаем перевод с английского на русский")
        #expect(preparing.detailText.contains("Английский -> русский"))
        #expect(translating.detailText.contains("Английский -> русский"))
    }

    @Test("Russian and English cache language identities are separate")
    func languageCacheSeparation() async throws {
        let russianKey = LocalDubbingPolicy.languageCacheComponent(
            language: .russian,
            translationBypassed: true
        )
        let englishKey = LocalDubbingPolicy.languageCacheComponent(
            language: .english,
            translationBypassed: false
        )
        #expect(russianKey != englishKey)

        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalDubbingTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let temporaryAudio = base.appendingPathComponent("audio.m4a")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 100).write(to: temporaryAudio)
        let cache = LocalDubbingCache(baseDirectory: base)
        let result = LocalDubbingResult(
            videoID: "video",
            title: "Title",
            cues: [CaptionCue(startTime: 0, endTime: 1, text: "Привет")],
            transcriptOrigin: .youtubeCaptions,
            sourceLanguage: .russian,
            translationBypassed: true,
            cacheIdentity: russianKey,
            voiceEngine: .supertonic3,
            audioFilename: "audio.m4a",
            transcriptFilename: "text.txt",
            metrics: LocalDubbingMetrics(
                wallTime: 1,
                minimumAvailableMemoryBytes: 1,
                peakResidentMemoryBytes: 1,
                modelCacheBytes: 1,
                outputBytes: 100,
                startingThermalState: 0,
                endingThermalState: 0
            )
        )
        _ = try await cache.store(
            result: result,
            temporaryAudioURL: temporaryAudio,
            transcriptText: "Привет"
        )
        #expect(await cache.load(videoID: "video", cacheIdentity: russianKey) != nil)
        #expect(await cache.load(videoID: "video", cacheIdentity: englishKey) == nil)
    }

    @Test("Resume identity is stable when the same source audio is rematerialized")
    func resumeIdentityIgnoresUnstableSourceContainerSize() throws {
        let first = LocalDubbingRequest(
            videoID: "video",
            title: "Title",
            sourceAudioURL: URL(fileURLWithPath: "/tmp/first-audio.m4a"),
            availableSourceCues: sourceCues,
            sourceCaptionLanguageCode: "ru",
            sourceLanguageOverride: "ru",
            maximumSourceDuration: 60
        )
        let rematerialized = LocalDubbingRequest(
            videoID: "video",
            title: "Title",
            sourceAudioURL: URL(fileURLWithPath: "/tmp/second-audio-with-different-size.m4a"),
            availableSourceCues: sourceCues,
            sourceCaptionLanguageCode: "ru",
            sourceLanguageOverride: "ru",
            maximumSourceDuration: 60
        )

        #expect(try LocalDubbingPolicy.cacheIdentityPayload(for: first)
            == LocalDubbingPolicy.cacheIdentityPayload(for: rematerialized))
    }

    @Test("Ready result deduplicates same item and language only")
    func readyResultDeduplication() {
        #expect(LocalDubbingPolicy.shouldReuseReadyResult(
            activeVideoID: "video",
            requestVideoID: "video",
            requestedLanguage: .russian,
            resultLanguage: .russian
        ))
        #expect(LocalDubbingPolicy.shouldReuseReadyResult(
            activeVideoID: "video",
            requestVideoID: "video",
            requestedLanguage: .unknown,
            resultLanguage: .russian
        ))
        #expect(!LocalDubbingPolicy.shouldReuseReadyResult(
            activeVideoID: "video",
            requestVideoID: "video",
            requestedLanguage: .english,
            resultLanguage: .russian
        ))
        #expect(!LocalDubbingPolicy.shouldReuseReadyResult(
            activeVideoID: "old",
            requestVideoID: "new",
            requestedLanguage: .russian,
            resultLanguage: .russian
        ))
    }

    @Test("Translated text preserves absolute source timing")
    func translationPreservesTiming() {
        let translated = LocalDubbingPolicy.translatedCues(
            source: sourceCues,
            translationsByIdentifier: [
                "1": "Как дела?",
                "0": "Привет.",
            ]
        )
        #expect(translated.map(\.text) == ["Привет.", "Как дела?"])
        #expect(translated.map(\.startTime) == [0.5, 2.4])
        #expect(translated.map(\.endTime) == [2.0, 4.1])
    }

    @Test("Missing translation cannot silently create an empty cue")
    func missingTranslationIsNotExported() {
        let translated = LocalDubbingPolicy.translatedCues(
            source: sourceCues,
            translationsByIdentifier: ["0": "Привет", "1": "   "]
        )
        #expect(translated.count == 1)
        #expect(translated[0].text == "Привет")
    }

    @Test("Synthesized segments keep rate 1.0 and never overlap")
    func synthesizedSegmentsKeepNaturalRate() {
        #expect(LocalDubbingAudioOwnershipPolicy.effectivePlaybackRate() == 1.0)
        #expect(LocalDubbingPolicy.scheduledStart(
            cueStart: 2.4,
            previousSegmentEnd: 5.0
        ) == 5.0)
        #expect(LocalDubbingPolicy.scheduledStart(
            cueStart: 8.0,
            previousSegmentEnd: 5.0
        ) == 8.0)
        #expect(LocalDubbingAudioOwnershipPolicy.shouldPauseSource(
            localPlaybackWillStart: true
        ))
        #expect(LocalDubbingAudioOwnershipPolicy.shouldSuppressSourceRate(
            localPlaybackIsActive: true,
            sourceRate: 1
        ))
        #expect(!LocalDubbingAudioOwnershipPolicy.shouldSuppressSourceRate(
            localPlaybackIsActive: false,
            sourceRate: 1
        ))
    }

    @Test("Translation requests use bounded stable batches")
    func boundedBatches() {
        let values = Array(0..<53)
        let batches = LocalDubbingPolicy.batches(values, size: 24)
        #expect(batches.map(\.count) == [24, 24, 5])
        #expect(batches.flatMap { $0 } == values)
    }

    @Test("Progress is branch-aware, work-based, monotonic, and below 100 until ready")
    func branchAwareProgress() {
        let russian = LocalDubbingProgressPlan(requiresASR: false, requiresTranslation: false)
        let english = LocalDubbingProgressPlan(requiresASR: false, requiresTranslation: true)
        let localASR = LocalDubbingProgressPlan(requiresASR: true, requiresTranslation: true)

        let russianVoiceStart = russian.overallProgress(phase: .preparingVoice, phaseProgress: 0)
        let englishTranslation = english.overallProgress(phase: .translation, phaseProgress: 0.5)
        let transcription = localASR.overallProgress(phase: .transcribing, phaseProgress: 0.5)
        #expect(russianVoiceStart < 0.10)
        #expect(englishTranslation > 0.05)
        #expect(transcription > 0.10)

        let sequence = [
            english.overallProgress(phase: .preparingAudio, phaseProgress: 1),
            english.overallProgress(phase: .determiningLanguage, phaseProgress: 1),
            english.overallProgress(phase: .translation, phaseProgress: 1),
            english.overallProgress(phase: .preparingVoice, phaseProgress: 1),
            english.overallProgress(phase: .synthesis, phaseProgress: 1),
            english.overallProgress(phase: .assembly, phaseProgress: 1),
            english.overallProgress(phase: .validation, phaseProgress: 1),
        ]
        #expect(zip(sequence, sequence.dropFirst()).allSatisfy { $0 <= $1 })
        #expect(sequence.allSatisfy { $0 < 1 })
        #expect(LocalDubbingProgressUpdate(stage: .ready, overallProgress: 1).overallProgress == 1)
    }

    @Test("Long TTS and resume progress use completed cue complexity")
    func weightedTTSProgressAndResume() {
        let cues = (0..<15).map { index in
            CaptionCue(
                startTime: Double(index),
                endTime: Double(index + 1),
                text: String(repeating: "слово ", count: index + 1)
            )
        }
        let resumed = Set(0..<13)
        let fraction = LocalDubbingPolicy.weightedSegmentCompletion(cues: cues, completed: resumed)
        #expect(fraction > 0.70)
        #expect(fraction != Double(13) / 15)
        #expect(fraction < 1)
        let plan = LocalDubbingProgressPlan(requiresASR: false, requiresTranslation: false)
        let overall = plan.overallProgress(phase: .synthesis, phaseProgress: fraction)
        #expect(overall > plan.overallProgress(phase: .synthesis, phaseProgress: 0))
        #expect(overall < plan.overallProgress(phase: .assembly, phaseProgress: 0))
    }

    @Test("Stalled work does not invent progress and VoiceOver announces stage changes only")
    func stalledProgressAndAnnouncements() {
        let plan = LocalDubbingProgressPlan(requiresASR: false, requiresTranslation: false)
        let stalled = LocalDubbingProgressUpdate(
            stage: .synthesizing(progress: 0.4),
            overallProgress: plan.overallProgress(phase: .synthesis, phaseProgress: 0.4),
            completedSegments: 6,
            totalSegments: 15,
            isRussianDirect: true
        )
        let sameStage = LocalDubbingProgressUpdate(
            stage: .synthesizing(progress: 0.4),
            overallProgress: plan.overallProgress(phase: .synthesis, phaseProgress: 0.4),
            completedSegments: 7,
            totalSegments: 15,
            isRussianDirect: true
        )
        let assembly = LocalDubbingProgressUpdate(
            stage: .assembling(progress: 0),
            overallProgress: plan.overallProgress(phase: .assembly, phaseProgress: 0)
        )
        #expect(stalled.overallProgress == sameStage.overallProgress)
        #expect(!LocalDubbingAccessibilityPolicy.shouldAnnounce(previous: stalled, current: sameStage))
        #expect(LocalDubbingAccessibilityPolicy.shouldAnnounce(previous: sameStage, current: assembly))
        #expect(stalled.statusText.contains("фрагмент 6 из 15"))
    }

    @Test("User-facing stage copy matches direct, translated, resumed, assembly, validation, and cache hit")
    func userFacingStageMapping() {
        let direct = LocalDubbingProgressUpdate(
            stage: .synthesizing(progress: 0.2),
            overallProgress: 0.2,
            completedSegments: 2,
            totalSegments: 10,
            isRussianDirect: true
        )
        let translated = LocalDubbingProgressUpdate(
            stage: .synthesizing(progress: 0.2),
            overallProgress: 0.2,
            completedSegments: 2,
            totalSegments: 10,
            isRussianDirect: false
        )
        let resumed = LocalDubbingProgressUpdate(
            stage: .synthesizing(progress: 0.8),
            overallProgress: 0.8,
            completedSegments: 13,
            totalSegments: 15,
            resumedFromSegments: 13,
            isRussianDirect: true
        )
        #expect(direct.statusText == "Озвучиваем русский текст, фрагмент 2 из 10")
        #expect(translated.statusText == "Озвучиваем фрагмент 2 из 10")
        #expect(resumed.statusText == "Продолжаем озвучку, готово 13 из 15")
        #expect(LocalDubbingProgressUpdate(
            stage: .assembling(progress: 0),
            overallProgress: 0.9
        ).statusText == "Собираем аудиодорожку")
        #expect(LocalDubbingProgressUpdate(
            stage: .validating,
            overallProgress: 0.98
        ).statusText == "Проверяем и сохраняем")
        #expect(LocalDubbingProgressUpdate(
            stage: .ready,
            overallProgress: 1
        ).statusText == "Готово")
    }

    @Test("Output identity is filesystem safe and stable")
    func safeVideoIdentity() {
        #expect(LocalDubbingPolicy.safeVideoID("abc/../secret") == "abc____secret")
        #expect(LocalDubbingPolicy.safeVideoID("dQw4w9WgXcQ") == "dQw4w9WgXcQ")
    }

    @Test("Cached result keeps Russian cues and engine metadata")
    func resultRoundTrip() throws {
        let metrics = LocalDubbingMetrics(
            wallTime: 12,
            minimumAvailableMemoryBytes: 2_000,
            peakResidentMemoryBytes: 1_000,
            modelCacheBytes: 400,
            outputBytes: 200,
            startingThermalState: 0,
            endingThermalState: 1
        )
        let value = LocalDubbingResult(
            videoID: "video",
            title: "Title",
            cues: [CaptionCue(startTime: 1, endTime: 2, text: "Привет")],
            transcriptOrigin: .parakeet,
            sourceLanguage: .russian,
            translationBypassed: true,
            cacheIdentity: "ru-direct",
            voiceEngine: .supertonic3,
            audioFilename: "Title-RU.m4a",
            transcriptFilename: "Title-RU.txt",
            metrics: metrics
        )
        let decoded = try JSONDecoder().decode(
            LocalDubbingResult.self,
            from: JSONEncoder().encode(value)
        )
        #expect(decoded == value)
        #expect(decoded.translationBypassed)
        #expect(decoded.sourceLanguage == .russian)
    }

    @Test("Local dubbing state owns the visible transcript surface")
    func localDubbingSuppressesUnrelatedSourceFailure() {
        #expect(LocalDubbingPresentationPolicy.transcriptSurface(
            stage: .synthesizing(progress: 0.71),
            hasResult: false,
            prefersRussian: true
        ) == .localProgress)
        #expect(LocalDubbingPresentationPolicy.transcriptSurface(
            stage: .ready,
            hasResult: true,
            prefersRussian: true
        ) == .russianTranscript)
        #expect(LocalDubbingPresentationPolicy.transcriptSurface(
            stage: .failed(message: "voice"),
            hasResult: false,
            prefersRussian: true
        ) == .localFailure)
        #expect(LocalDubbingPresentationPolicy.transcriptSurface(
            stage: .ready,
            hasResult: true,
            prefersRussian: false
        ) == .source)
        #expect(LocalDubbingPresentationPolicy.visibleProgressIndicatorCount(
            stage: .synthesizing(progress: 0.4)
        ) == 1)
        #expect(!LocalDubbingPresentationPolicy.showsPrimaryStartAction(
            stage: .failed(message: LocalDubbingFailure.sourceLanguageChoiceRequired.userMessage),
            failure: .sourceLanguageChoiceRequired
        ))
    }

    @Test("Transcript header never labels strong English cues as Russian")
    func honestTranscriptHeader() {
        let english = (0..<12).map {
            CaptionCue(startTime: Double($0), endTime: Double($0 + 1), text: "Clearly English output text with a sufficiently large sample")
        }
        let russian = (0..<12).map {
            CaptionCue(startTime: Double($0), endTime: Double($0 + 1), text: "Явно русский итоговый текст с достаточно большой выборкой")
        }
        #expect(LocalDubbingPresentationPolicy.transcriptHeaderLabel(
            cues: english,
            count: english.count
        ) == "Стенограмма озвучки, реплик: 12")
        #expect(LocalDubbingPresentationPolicy.transcriptHeaderLabel(
            cues: russian,
            count: russian.count
        ) == "Русская стенограмма, реплик: 12")
    }

    @Test("Seek clamps safely and preserves pause semantics")
    func seekPolicy() {
        #expect(LocalDubbingPolicy.normalizedSeek(-10, duration: 120) == 0)
        #expect(LocalDubbingPolicy.normalizedSeek(42, duration: 120) == 42)
        #expect(LocalDubbingPolicy.normalizedSeek(999, duration: 120) == 120)
        #expect(LocalDubbingPolicy.normalizedSeek(.nan, duration: 120) == 0)
    }

    @Test("Resume schedules every valid segment exactly once")
    func segmentResumePlan() {
        let completed: Set<Int> = [0, 1, 2, 8]
        let valid: Set<Int> = [0, 2, 8]
        #expect(LocalDubbingPolicy.firstIncompleteSegment(
            total: 5,
            completed: completed,
            valid: { valid.contains($0) }
        ) == 1)
        #expect(LocalDubbingPolicy.pendingSegmentIndices(
            total: 5,
            completed: completed,
            valid: { valid.contains($0) }
        ) == [1, 3, 4])
    }

    @Test("Manifest and playback state survive recreation")
    func durableManifestAndPlayback() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalDubbingTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let cache = LocalDubbingCache(baseDirectory: base)
        let manifest = LocalDubbingWorkManifest(
            cacheIdentity: "identity",
            videoID: "video",
            title: "Title",
            phase: .translation,
            sourceCues: sourceCues,
            transcriptOrigin: .parakeet,
            sourceLanguageDecision: LocalDubbingLanguageDecision(
                language: .russian,
                confidence: 1,
                usedOverride: true,
                metadataLanguageCode: "ru",
                detectedLanguageCode: "ru"
            ),
            translationBypassed: true,
            translationsByIndex: [0: "Привет", 1: "Как дела"],
            voiceEngine: .supertonic3,
            completedSegmentIndices: [0]
        )
        try await cache.saveWork(manifest)
        let restoredManifest = await cache.loadWork(videoID: "video", cacheIdentity: "identity")
        #expect(restoredManifest?.cacheIdentity == manifest.cacheIdentity)
        #expect(restoredManifest?.phase == .translation)
        #expect(restoredManifest?.sourceCues == sourceCues)
        #expect(restoredManifest?.completedSegmentIndices == [0])
        #expect(restoredManifest?.translationsByIndex == manifest.translationsByIndex)
        #expect(restoredManifest?.sourceLanguageDecision?.language == .russian)
        #expect(restoredManifest?.translationBypassed == true)
        #expect(LocalDubbingPolicy.pendingSegmentIndices(
            total: 2,
            completed: restoredManifest?.completedSegmentIndices ?? [],
            valid: { $0 == 0 }
        ) == [1])

        let snapshot = LocalDubbingPlaybackSnapshot(
            videoID: "video",
            position: 37,
            duration: 120,
            wasPlaying: true
        )
        try await cache.savePlayback(snapshot)
        #expect(await cache.loadPlayback(videoID: "video") == snapshot)
    }

    @Test("Language selection migrates unknown work without repeating transcript work")
    func languageSelectionContinuesUnknownWork() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalDubbingTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let cache = LocalDubbingCache(baseDirectory: base)
        let manifest = LocalDubbingWorkManifest(
            cacheIdentity: "unknown",
            videoID: "video",
            title: "Title",
            sourceCues: sourceCues,
            transcriptOrigin: .parakeet,
            sourceLanguageDecision: LocalDubbingLanguageDecision(
                language: .unknown,
                confidence: 0.5,
                usedOverride: false,
                metadataLanguageCode: nil,
                detectedLanguageCode: nil
            )
        )
        try await cache.saveWork(manifest)
        let migrated = await cache.loadWork(
            videoID: "video",
            cacheIdentity: "english-choice",
            migrateUnknownLanguage: true
        )
        #expect(migrated?.cacheIdentity == "english-choice")
        #expect(migrated?.sourceCues == sourceCues)
        #expect(migrated?.sourceLanguageDecision == nil)
    }

    @Test("Versioned cache rejects the previous incorrect ready artifact")
    func cacheVersionRejectsWrongReadyArtifact() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalDubbingTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let audio = base.appendingPathComponent("audio.m4a")
        try Data(repeating: 1, count: 100).write(to: audio)
        let cache = LocalDubbingCache(baseDirectory: base)
        let wrong = LocalDubbingResult(
            algorithmVersion: LocalDubbingPolicy.algorithmVersion - 1,
            videoID: "video",
            title: "Title",
            cues: [CaptionCue(startTime: 0, endTime: 1, text: "English text")],
            transcriptOrigin: .parakeet,
            sourceLanguage: .russian,
            translationBypassed: true,
            cacheIdentity: "wrong",
            voiceEngine: .supertonic3,
            audioFilename: "audio.m4a",
            transcriptFilename: "text.txt",
            metrics: LocalDubbingMetrics(
                wallTime: 1,
                minimumAvailableMemoryBytes: 1,
                peakResidentMemoryBytes: 1,
                modelCacheBytes: 1,
                outputBytes: 100,
                startingThermalState: 0,
                endingThermalState: 0
            )
        )
        _ = try await cache.store(
            result: wrong,
            temporaryAudioURL: audio,
            transcriptText: "English text"
        )
        #expect(await cache.load(videoID: "video", cacheIdentity: "wrong") == nil)
    }

    @Test("Corrupt or incompatible partial state is isolated from final output")
    func corruptPartialStateIsInvalidated() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalDubbingTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let work = base
            .appendingPathComponent("AxrTubeDubbing/Work/v\(LocalDubbingPolicy.algorithmVersion)/video")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try Data("not-json".utf8).write(to: work.appendingPathComponent("manifest.json"))
        let cache = LocalDubbingCache(baseDirectory: base)
        #expect(await cache.loadWork(videoID: "video", cacheIdentity: "identity") == nil)
        #expect(!FileManager.default.fileExists(atPath: work.path))
    }
}
