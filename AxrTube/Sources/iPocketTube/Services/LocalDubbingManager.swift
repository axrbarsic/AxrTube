#if os(iOS)
import AVFoundation
import Foundation
import Observation
import Translation
import UIKit
import iPocketTubeCore

@MainActor
@Observable
final class LocalDubbingManager {
    public private(set) var stage: LocalDubbingStage = .idle
    public private(set) var progressUpdate = LocalDubbingProgressUpdate(
        stage: .idle,
        overallProgress: 0
    )
    public private(set) var failure: LocalDubbingFailure?
    public private(set) var result: LocalDubbingResult?
    public private(set) var audioURL: URL?
    public private(set) var transcriptURL: URL?
    public private(set) var activeVideoID: String?
    public private(set) var isPlaying = false
    public private(set) var currentTime: TimeInterval = 0
    public private(set) var duration: TimeInterval = 0
    public private(set) var isScrubbing = false
    public private(set) var restoredPlaybackIntent = false
    public private(set) var translationConfiguration: TranslationSession.Configuration?
    public private(set) var translationAvailability: LocalDubbingTranslationAvailability?

    @ObservationIgnored private let service: LocalDubbingService
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var audioPlayer: AVPlayer?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var playbackEndObserver: NSObjectProtocol?
    @ObservationIgnored private var lifecycleObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var onWillStartPlayback: (() -> Void)?
    @ObservationIgnored private var resumeAfterScrub = false
    @ObservationIgnored private var lastPersistedAt = Date.distantPast
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var pendingTranslationRequest: LocalDubbingRequest?
    @ObservationIgnored private var isPreparingTranslation = false

    init(service: LocalDubbingService) {
        self.service = service
        installLifecycleObservers()
    }

    func loadCachedResult(videoID: String) async {
        guard task == nil else { return }
        if let cached = await service.cachedResult(videoID: videoID) {
            if activeVideoID != videoID { tearDownPlayer() }
            activeVideoID = videoID
            result = cached.result
            audioURL = cached.audioURL
            transcriptURL = cached.transcriptURL
            stage = .ready
            progressUpdate = LocalDubbingProgressUpdate(stage: .ready, overallProgress: 1)
            failure = nil
            await restorePlaybackState(videoID: videoID, audioURL: cached.audioURL)
        }
    }

    func resumeIfAvailable(request: LocalDubbingRequest) async {
        guard await service.hasResumableWork(videoID: request.videoID) else { return }
        start(request: request)
    }

    func configureAudioOwnership(onWillStartPlayback: @escaping () -> Void) {
        self.onWillStartPlayback = onWillStartPlayback
    }

    func waitForAudio(videoID: String) {
        guard !stage.isActive || activeVideoID != videoID else { return }
        cancel(clearResult: activeVideoID != videoID)
        activeVideoID = videoID
        stage = .waitingForAudio
        progressUpdate = LocalDubbingProgressUpdate(stage: .waitingForAudio, overallProgress: 0)
        failure = nil
    }

    func start(
        request: LocalDubbingRequest,
        preservingPreparedTranslationSession: Bool = false
    ) {
        let requestedLanguage = LocalDubbingPolicy.sourceLanguage(
            for: request.sourceLanguageOverride ?? request.sourceCaptionLanguageCode
        )
        if activeVideoID == request.videoID,
           stage == .ready,
           let result,
           LocalDubbingPolicy.shouldReuseReadyResult(
               activeVideoID: activeVideoID,
               requestVideoID: request.videoID,
               requestedLanguage: requestedLanguage,
               resultLanguage: result.sourceLanguage
           ) {
            if Self.smokeLoggingEnabled {
                print("AXRTUBE_DUBBING_SMOKE_CACHE_HIT manager language=\(result.sourceLanguage.rawValue)")
            }
            return
        }
        if activeVideoID == request.videoID, stage.isActive {
            if task != nil || !preservingPreparedTranslationSession { return }
        }
        if preservingPreparedTranslationSession {
            task?.cancel()
            task = nil
        } else {
            cancel(clearResult: activeVideoID != request.videoID)
        }
        activeVideoID = request.videoID
        failure = nil
        generation &+= 1
        let expectedGeneration = generation
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let resolved = try await self.service.process(request: request) { [weak self] update in
                    guard let self,
                          self.generation == expectedGeneration,
                          self.activeVideoID == request.videoID else { return }
                    let previous = self.progressUpdate
                    let monotonic = LocalDubbingProgressUpdate(
                        stage: update.stage,
                        overallProgress: max(previous.overallProgress, update.overallProgress),
                        completedSegments: update.completedSegments,
                        totalSegments: update.totalSegments,
                        resumedFromSegments: update.resumedFromSegments,
                        isRussianDirect: update.isRussianDirect
                    )
                    self.stage = monotonic.stage
                    self.progressUpdate = monotonic
                    if LocalDubbingAccessibilityPolicy.shouldAnnounce(
                        previous: previous,
                        current: monotonic
                    ) {
                        UIAccessibility.post(
                            notification: .announcement,
                            argument: monotonic.statusText
                        )
                    }
                    if Self.smokeLoggingEnabled {
                        print("AXRTUBE_DUBBING_SMOKE_STAGE \(monotonic.statusText) \(Int(monotonic.overallProgress * 100))")
                    }
                }
                guard !Task.isCancelled,
                      self.generation == expectedGeneration,
                      self.activeVideoID == request.videoID else { return }
                self.result = resolved.result
                self.audioURL = resolved.audioURL
                self.transcriptURL = resolved.transcriptURL
                self.stage = .ready
                self.progressUpdate = LocalDubbingProgressUpdate(stage: .ready, overallProgress: 1)
                self.failure = nil
                self.task = nil
                await self.restorePlaybackState(
                    videoID: request.videoID,
                    audioURL: resolved.audioURL
                )
                if Self.smokeLoggingEnabled {
                    let metrics = resolved.result.metrics
                    print("AXRTUBE_DUBBING_SMOKE_READY wall=\(metrics.wallTime) minAvailable=\(metrics.minimumAvailableMemoryBytes) peakResident=\(metrics.peakResidentMemoryBytes) models=\(metrics.modelCacheBytes) output=\(metrics.outputBytes) thermal=\(metrics.startingThermalState):\(metrics.endingThermalState)")
                    print("AXRTUBE_DUBBING_SMOKE_AUDIO \(resolved.audioURL.path)")
                    print("AXRTUBE_DUBBING_SMOKE_TRANSCRIPT \(resolved.transcriptURL.path)")
                    self.togglePlayback()
                    print("AXRTUBE_DUBBING_SMOKE_PLAYBACK_STARTED")
                    Task { @MainActor [weak self] in
                        try? await Task.sleep(for: .seconds(1))
                        guard let self else { return }
                        let forward = min(max(1, self.duration * 0.6), 8)
                        self.seek(to: forward)
                        print("AXRTUBE_DUBBING_SMOKE_SEEK_FORWARD position=\(forward) playing=\(self.isPlaying)")
                        try? await Task.sleep(for: .seconds(1))
                        self.seek(to: 1)
                        print("AXRTUBE_DUBBING_SMOKE_SEEK_BACKWARD position=1.0 playing=\(self.isPlaying)")
                        try? await Task.sleep(for: .seconds(1))
                        self.stopPlayback()
                        print("AXRTUBE_DUBBING_SMOKE_PLAYBACK_STOPPED")
                    }
                }
            } catch is CancellationError {
                guard self.generation == expectedGeneration else { return }
                self.stage = .cancelled
                self.failure = nil
                self.task = nil
            } catch let failure as LocalDubbingFailure {
                guard self.generation == expectedGeneration else { return }
                if failure == .translationPreparationRequired {
                    self.pendingTranslationRequest = request
                    self.translationAvailability = .supported
                    self.translationConfiguration = TranslationSession.Configuration(
                        source: Locale.Language(identifier: "en"),
                        target: Locale.Language(identifier: "ru")
                    )
                    self.stage = .preparingTranslationAssets
                    self.progressUpdate = LocalDubbingProgressUpdate(
                        stage: .preparingTranslationAssets,
                        overallProgress: self.progressUpdate.overallProgress
                    )
                    self.failure = nil
                    self.task = nil
                    return
                }
                if failure == .translationPairUnsupported {
                    self.translationAvailability = .unsupported
                }
                if failure == .jobAlreadyActive {
                    self.task = nil
                    return
                }
                self.stage = .failed(message: failure.userMessage)
                self.failure = failure
                self.task = nil
                if Self.smokeLoggingEnabled {
                    print("AXRTUBE_DUBBING_SMOKE_FAILED \(failure.userMessage)")
                }
            } catch {
                guard self.generation == expectedGeneration else { return }
                self.stage = .failed(message: error.localizedDescription)
                self.failure = nil
                self.task = nil
                if Self.smokeLoggingEnabled {
                    print("AXRTUBE_DUBBING_SMOKE_FAILED \(error.localizedDescription)")
                }
            }
        }
    }

    func prepareTranslation(using session: TranslationSession) async {
        guard LocalDubbingTranslationPolicy.shouldBeginPreparation(
            isPreparing: isPreparingTranslation,
            hasConfiguration: translationConfiguration != nil
        ), let request = pendingTranslationRequest else { return }
        isPreparingTranslation = true
        stage = .preparingTranslationAssets
        progressUpdate = LocalDubbingProgressUpdate(
            stage: .preparingTranslationAssets,
            overallProgress: progressUpdate.overallProgress
        )
        do {
            try await service.prepareTranslation(using: session)
            translationAvailability = .installed
            translationConfiguration = nil
            pendingTranslationRequest = nil
            isPreparingTranslation = false
            failure = nil
            start(request: request, preservingPreparedTranslationSession: true)
        } catch is CancellationError {
            isPreparingTranslation = false
        } catch {
            translationConfiguration = nil
            isPreparingTranslation = false
            failure = .translationPreparationFailed
            stage = .failed(message: LocalDubbingFailure.translationPreparationFailed.userMessage)
        }
    }

    func retryTranslationPreparation() {
        guard pendingTranslationRequest != nil, !isPreparingTranslation else { return }
        failure = nil
        stage = .preparingTranslationAssets
        progressUpdate = LocalDubbingProgressUpdate(
            stage: .preparingTranslationAssets,
            overallProgress: progressUpdate.overallProgress
        )
        translationConfiguration = TranslationSession.Configuration(
            source: Locale.Language(identifier: "en"),
            target: Locale.Language(identifier: "ru")
        )
    }

    func cancel(clearResult: Bool = false) {
        generation &+= 1
        task?.cancel()
        task = nil
        service.cancel()
        translationConfiguration = nil
        pendingTranslationRequest = nil
        isPreparingTranslation = false
        stopPlayback()
        if clearResult {
            tearDownPlayer()
            result = nil
            audioURL = nil
            transcriptURL = nil
            activeVideoID = nil
            currentTime = 0
            duration = 0
            restoredPlaybackIntent = false
            stage = .idle
            progressUpdate = LocalDubbingProgressUpdate(stage: .idle, overallProgress: 0)
            failure = nil
        } else if stage.isActive {
            stage = .cancelled
            failure = nil
        }
    }

    func togglePlayback() {
        if isPlaying {
            stopPlayback()
            return
        }
        guard let audioURL else { return }
        if LocalDubbingAudioOwnershipPolicy.shouldPauseSource(localPlaybackWillStart: true) {
            onWillStartPlayback?()
        }
        let player: AVPlayer
        if let existing = audioPlayer,
           (existing.currentItem?.asset as? AVURLAsset)?.url == audioURL {
            player = existing
        } else {
            tearDownPlayer()
            let item = AVPlayerItem(url: audioURL)
            let created = AVPlayer(playerItem: item)
            audioPlayer = created
            installPlaybackObservers(player: created, item: item)
            player = created
        }
        let target = LocalDubbingPolicy.normalizedSeek(currentTime, duration: duration)
        player.seek(
            to: CMTime(seconds: target, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
        player.playImmediately(atRate: LocalDubbingAudioOwnershipPolicy.effectivePlaybackRate())
        isPlaying = true
        restoredPlaybackIntent = false
        persistPlaybackState(wasPlaying: true, force: true)
    }

    func stopPlayback() {
        audioPlayer?.pause()
        isPlaying = false
        restoredPlaybackIntent = false
        persistPlaybackState(wasPlaying: false, force: true)
    }

    func beginScrubbing() {
        guard duration > 0 else { return }
        isScrubbing = true
        resumeAfterScrub = isPlaying
        audioPlayer?.pause()
        isPlaying = false
    }

    func updateScrub(to requested: TimeInterval) {
        currentTime = LocalDubbingPolicy.normalizedSeek(requested, duration: duration)
    }

    func commitScrubbing() {
        guard isScrubbing else { return }
        isScrubbing = false
        let shouldResume = resumeAfterScrub
        resumeAfterScrub = false
        let target = LocalDubbingPolicy.normalizedSeek(currentTime, duration: duration)
        audioPlayer?.seek(
            to: CMTime(seconds: target, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        ) { [weak self] finished in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.currentTime = target
                if shouldResume, finished {
                    self.onWillStartPlayback?()
                    self.audioPlayer?.playImmediately(
                        atRate: LocalDubbingAudioOwnershipPolicy.effectivePlaybackRate()
                    )
                    self.isPlaying = true
                }
                self.persistPlaybackState(wasPlaying: self.isPlaying, force: true)
            }
        }
        if audioPlayer == nil {
            persistPlaybackState(wasPlaying: false, force: true)
        }
    }

    func seek(to requested: TimeInterval) {
        let target = LocalDubbingPolicy.normalizedSeek(requested, duration: duration)
        currentTime = target
        audioPlayer?.seek(
            to: CMTime(seconds: target, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
        persistPlaybackState(wasPlaying: isPlaying, force: true)
    }

    var translatedCues: [CaptionCue] { result?.cues ?? [] }
    var displayProgress: Double { progressUpdate.overallProgress }
    var progressStatus: String { progressUpdate.statusText }
    var progressDetail: String { progressUpdate.detailText }
    var needsSourceLanguageSelection: Bool { failure == .sourceLanguageChoiceRequired }

    var transcriptDocument: TranscriptExportDocument? {
        guard let result else { return nil }
        return TranscriptExportDocument(
            title: "\(result.title) (русская озвучка)",
            videoID: result.videoID,
            source: .russianDubbing,
            generatedAt: result.createdAt,
            cues: result.cues
        )
    }

    nonisolated private static var smokeLoggingEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains("--uitesting-dubbing-auto-start")
    }

    private func installPlaybackObservers(player: AVPlayer, item: AVPlayerItem) {
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self, !self.isScrubbing else { return }
                let seconds = time.seconds
                if seconds.isFinite { self.currentTime = max(0, seconds) }
                self.persistPlaybackState(wasPlaying: self.isPlaying, force: false)
            }
        }
        playbackEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.currentTime = 0
                self.isPlaying = false
                self.persistPlaybackState(wasPlaying: false, force: true)
            }
        }
    }

    private func tearDownPlayer() {
        if let timeObserver, let audioPlayer {
            audioPlayer.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        if let playbackEndObserver {
            NotificationCenter.default.removeObserver(playbackEndObserver)
        }
        playbackEndObserver = nil
        audioPlayer?.pause()
        audioPlayer = nil
        isPlaying = false
        isScrubbing = false
    }

    private func restorePlaybackState(videoID: String, audioURL: URL) async {
        let asset = AVURLAsset(url: audioURL)
        let loadedDuration = (try? await asset.load(.duration).seconds) ?? 0
        duration = loadedDuration.isFinite ? max(0, loadedDuration) : 0
        if let snapshot = await service.loadPlayback(videoID: videoID) {
            currentTime = LocalDubbingPolicy.normalizedSeek(snapshot.position, duration: duration)
            restoredPlaybackIntent = snapshot.wasPlaying
            if Self.smokeLoggingEnabled {
                print("AXRTUBE_DUBBING_SMOKE_PLAYBACK_RESTORED position=\(currentTime) duration=\(duration) intent=\(snapshot.wasPlaying)")
            }
        } else {
            currentTime = 0
            restoredPlaybackIntent = false
        }
    }

    private func persistPlaybackState(wasPlaying: Bool, force: Bool) {
        guard let activeVideoID, duration > 0 else { return }
        let now = Date()
        guard force || now.timeIntervalSince(lastPersistedAt) >= 2 else { return }
        lastPersistedAt = now
        let snapshot = LocalDubbingPlaybackSnapshot(
            videoID: activeVideoID,
            position: LocalDubbingPolicy.normalizedSeek(currentTime, duration: duration),
            duration: duration,
            wasPlaying: wasPlaying
        )
        Task { [service] in await service.savePlayback(snapshot) }
    }

    private func installLifecycleObservers() {
        let center = NotificationCenter.default
        lifecycleObservers.append(center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.persistPlaybackState(wasPlaying: self?.isPlaying ?? false, force: true)
            }
        })
        lifecycleObservers.append(center.addObserver(
            forName: UIApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.persistPlaybackState(wasPlaying: self?.isPlaying ?? false, force: true)
            }
        })
        lifecycleObservers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
            Task { @MainActor [weak self] in
                guard let self, self.isPlaying else { return }
                self.audioPlayer?.pause()
                self.isPlaying = false
                self.restoredPlaybackIntent = true
                self.persistPlaybackState(wasPlaying: true, force: true)
            }
        })
    }
}
#endif
