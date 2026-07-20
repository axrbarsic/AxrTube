#if os(iOS)
import AVFoundation
import Foundation
import Observation
import OSLog
import iPocketTubeCore

private let instantAudioLog = Logger(
    subsystem: "com.alexlane.smarttube.local",
    category: "InstantAudio"
)

@MainActor
@Observable
public final class AudioFirstPlaybackCoordinator {
    public enum Status: Equatable {
        case idle
        case resolving
        case buffering
        case reconnecting
        case waitingForWiFi
        case playing
        case preparingAudio
        case finalizationPending(String)
        case completed
        case failed(String)
    }

    public private(set) var currentVideo: Video?
    public private(set) var status: Status = .idle
    public private(set) var downloadProgress: Double = 0
    public private(set) var bufferedProgress: Double = 0
    public private(set) var lastTTFAMilliseconds: Int?
    /// The long-lived PlaybackViewModel is the only UI time source. The reducer
    /// still rejects stale download/finalizer callbacks, but it no longer owns a
    /// second scrubber clock that can reset independently after scene changes.
    public var displayedPlaybackTime: TimeInterval { playerState.vm.currentTime }

    private let api: InnerTubeAPI
    private let playerState: PlayerStateStore
    private let settingsStore: SettingsStore
    private let playbackLiveActivity: PlaybackLiveActivityController
    private let transcriptSummary: TranscriptSummaryManager
    private let fallbackService: VideoDownloadService
    private var workTask: Task<Void, Never>?
    private var timelineTask: Task<Void, Never>?
    private var positionHydrationTask: Task<Void, Never>?
    private var captionMetadataTask: Task<Void, Never>?
    private var captionIdentity: CaptionPlaybackIdentity?
    private var pendingDubbingVideoID: String?
    private var pendingDubbingSourceLanguageOverride: String?
    private var resourceLoader: ProgressiveAudioResourceLoader?
    private var playbackState = ProgressiveAudioStateMachine()
    private var milestones = InstantAudioMilestones()
    private var currentPlan: OfflineAudioDownloadPlan?
    private var tapStartedAt = ContinuousClock.now
    private var commandGate = PlaybackCommandGate()
    private var authoritativeState = AudioFirstAuthoritativeState()
    private var activeLoaderID: UUID?
    private var supervisedLoader: ProgressiveAudioResourceLoader?
    private var supervisedLoaderID: UUID?
    private var supervisedVideoID: String?
    private var reconciliationTask: Task<Void, Never>?
    private var reconciliationVideoID: String?
    private var reconciliationGeneration: UInt64 = 0
    private var reconciliationWatchdogTask: Task<Void, Never>?
    private var applicationIsActive = false
    private var wasPlayingBeforeScrub = false
    private var lastPositionCheckpointAt: Date?
    /// Committed only after a user-selected command produces real timeline
    /// movement. System/interruption resumes never create a history activation.
    private var pendingHistoryActivation: (videoID: String, kind: OfflineMediaKind, generation: UInt64)?
    private let signposter = OSSignposter(logger: instantAudioLog)
    private var ttfaSignpostState: OSSignpostIntervalState?

    public init(
        api: InnerTubeAPI,
        playerState: PlayerStateStore,
        settingsStore: SettingsStore,
        playbackLiveActivity: PlaybackLiveActivityController,
        transcriptSummary: TranscriptSummaryManager
    ) {
        self.api = api
        self.playerState = playerState
        self.settingsStore = settingsStore
        self.playbackLiveActivity = playbackLiveActivity
        self.transcriptSummary = transcriptSummary
        self.fallbackService = VideoDownloadService(api: api)
    }

    public var isVisible: Bool { currentVideo != nil && status != .idle }

    public var statusText: String {
        switch status {
        case .idle: ""
        case .resolving: String(localized: "Preparing audio", bundle: .module)
        case .buffering: String(localized: "Buffering audio", bundle: .module)
        case .reconnecting: String(localized: "Reconnecting…", bundle: .module)
        case .waitingForWiFi: String(localized: "Waiting for Wi-Fi", bundle: .module)
        case .playing: String(localized: "Playing while downloading", bundle: .module)
        case .preparingAudio: String(localized: "Preparing audio from MP4", bundle: .module)
        case .finalizationPending: String(localized: "Playback is available. Offline saving needs retry.", bundle: .module)
        case .completed: String(localized: "Saved offline", bundle: .module)
        case .failed(let message): message
        }
    }

    public func open(video: Video) {
        persistCurrentPosition(force: true)
        cancelSupervisedDownload(ifMatching: video.id)
        if currentVideo?.id == video.id, isVisible {
            if case .failed = status {
                // Retry below: a fresh metadata resolve keeps verified sparse bytes.
            } else if case .finalizationPending = status {
                // Retry below: a complete sparse cache re-enters only validation
                // and local finalization; its verified media bytes are preserved.
            } else {
                if !playerState.vm.isPlaying, playerState.vm.player.currentItem != nil {
                    togglePlayPauseByUser()
                }
                return
            }
        }

        if currentVideo?.id != video.id {
            transcriptSummary.reset()
            pendingDubbingVideoID = nil
            pendingDubbingSourceLanguageOverride = nil
            playerState.vm.localDubbingManager.cancel(clearResult: true)
        }
        let generation = commandGate.advance()
        playbackLiveActivity.stop()
        cancelActiveWork(markCancelled: false, stopPlayer: false)
        currentVideo = video
        captionIdentity = playerState.vm.beginPreparedAudioCaptions(video: video)
        lastPositionCheckpointAt = nil
        pendingHistoryActivation = (
            videoID: video.id,
            kind: video.localMediaKind ?? .audio,
            generation: generation
        )
        let durableProgress = DownloadStore.shared.entry(videoId: video.id, kind: .audio)?.progress ?? 0
        apply(.begin(generation: generation, durableProgress: durableProgress))
        bufferedProgress = 0
        playbackState = ProgressiveAudioStateMachine()
        milestones = InstantAudioMilestones()
        currentPlan = nil
        lastTTFAMilliseconds = nil
        tapStartedAt = .now
        ttfaSignpostState = signposter.beginInterval("TapToFirstTimeline")
        markTiming("tap")
        AudioDiagnostics.shared.record(
            source: "audio-first",
            event: "command.open",
            decision: DownloadStore.shared.isHydrated ? "manifestReady" : "manifestNotReady",
            player: playerState.vm.player,
            itemID: video.id,
            commandGeneration: generation
        )
        playerState.prepareAudioFirst(video: video)
        positionHydrationTask = Task { [weak self] in
            let duration = video.duration ?? self?.playerState.vm.duration ?? 0
            let saved = await VideoStateStore.shared.restoredPosition(for: video.id, actualDuration: duration)
            guard let self, self.commandGate.isCurrent(generation), self.currentVideo?.id == video.id else { return }
            self.apply(.userSeek(generation: generation, position: saved))
        }

        if let completed = completedLocalEntry(for: video) {
            workTask = Task { [weak self] in
                await self?.openLocal(completed, generation: generation)
            }
            return
        }

        guard DownloadStore.shared.claimForPlayback(video: video, kind: .audio) else {
            if let active = DownloadStore.shared.entry(videoId: video.id, kind: .audio), active.status.isActive {
                apply(.buffering(generation: generation))
            }
            return
        }
        bufferedProgress = durableProgress
        DownloadStore.shared.update(
            videoId: video.id,
            kind: .audio,
            status: .fetching,
            progress: max(0.02, durableProgress)
        )
        workTask = Task { [weak self] in await self?.resolveAndStart(video: video, generation: generation) }
    }

    public func close() {
        close(markCancelled: true)
    }

    public func requestRussianDubbing(sourceLanguageOverride: String? = nil) {
        guard let video = currentVideo else { return }
        if let audioURL = completedLocalAudioURL(for: video.id) {
            startRussianDubbing(
                video: video,
                audioURL: audioURL,
                sourceLanguageOverride: sourceLanguageOverride
            )
        } else {
            pendingDubbingVideoID = video.id
            pendingDubbingSourceLanguageOverride = sourceLanguageOverride
            playerState.vm.localDubbingManager.waitForAudio(videoID: video.id)
        }
    }

    public func cancelRussianDubbing() {
        pendingDubbingVideoID = nil
        pendingDubbingSourceLanguageOverride = nil
        playerState.vm.localDubbingManager.cancel()
    }

    public func resumeRussianDubbingIfNeeded() {
        guard let video = currentVideo,
              let audioURL = completedLocalAudioURL(for: video.id) else { return }
        resumeRussianDubbingIfNeeded(video: video, audioURL: audioURL)
    }

    /// UI-originated play/pause. Only a user Play activation advances history;
    /// Pause, remote commands, interruption recovery, and lifecycle callbacks do not.
    public func togglePlayPauseByUser() {
        guard let video = currentVideo, playerState.vm.player.currentItem != nil else { return }
        let wasPlaying = playerState.vm.isPlaying
        playerState.vm.togglePlayPause()
        synchronizeLiveActivity(force: true)
        if wasPlaying { persistCurrentPosition(force: true) }
        if !wasPlaying {
            pendingHistoryActivation = (
                videoID: video.id,
                kind: video.localMediaKind ?? .audio,
                generation: commandGate.generation
            )
        }
    }

    /// Idempotent foreground reconciliation for durable, non-user-paused jobs.
    /// The same coordinator owns both playback and background fill, preventing a
    /// second download manager from racing the sparse range manifest.
    public func reconcileDownloads(trigger: String) {
        guard applicationIsActive, reconciliationTask == nil, supervisedLoader == nil else { return }
        guard let entry = DownloadStore.shared.automaticallyResumableEntries
            .filter({ $0.videoId != currentVideo?.id })
            .sorted(by: {
                ($0.downloadedAt ?? .distantPast) < ($1.downloadedAt ?? .distantPast)
            })
            .first else { return }

        DownloadStore.shared.markAutomaticRecoveryPending(videoId: entry.videoId, kind: entry.kind)
        reconciliationGeneration &+= 1
        let generation = reconciliationGeneration
        reconciliationVideoID = entry.videoId
        AudioDiagnostics.shared.record(
            source: "download-supervisor",
            event: "reconcile.begin",
            decision: trigger,
            player: playerState.vm.player,
            itemID: entry.videoId
        )
        reconciliationTask = Task { [weak self] in
            await self?.resumeIncompleteAudio(entry, reconciliationGeneration: generation)
        }
    }

    public func setApplicationActive(_ active: Bool) {
        applicationIsActive = active
        if active {
            synchronizePlaybackTime(reason: "application active")
            reconcileDownloads(trigger: "foreground")
            startReconciliationWatchdog()
        } else {
            persistCurrentPosition(force: true)
            reconciliationWatchdogTask?.cancel()
            reconciliationWatchdogTask = nil
        }
    }

    public func synchronizePlaybackTime(reason: String) {
        guard currentVideo != nil, playerState.vm.player.currentItem != nil else { return }
        playerState.vm.synchronizePlaybackTimeFromPlayer(reason: reason)
        let actual = playerState.vm.currentTime
        guard actual.isFinite, actual >= 0 else { return }
        apply(.timeline(generation: commandGate.generation, position: actual))
    }

    public func pauseDownload(_ entry: DownloadedVideo) {
        guard entry.kind == .audio else { return }
        if reconciliationVideoID == entry.videoId {
            reconciliationGeneration &+= 1
            reconciliationTask?.cancel()
            reconciliationTask = nil
            reconciliationVideoID = nil
        }
        if supervisedVideoID == entry.videoId {
            supervisedLoader?.cancel(discardCache: false)
            clearSupervisedDownload(discardCache: false)
        }
        DownloadStore.shared.markUserPaused(videoId: entry.videoId, kind: entry.kind)
    }

    public func clampedSeekTime(_ requested: TimeInterval) -> TimeInterval {
        playbackState.clampedSeekTime(requested, duration: playerState.vm.duration)
    }

    public func beginScrubbing() {
        synchronizePlaybackTime(reason: "downloads scrub begin")
        wasPlayingBeforeScrub = playerState.vm.beginAudioFirstScrubbing()
    }

    public func updateScrubbing(to time: TimeInterval) {
        playerState.vm.updateScrub(to: clampedSeekTime(time))
    }

    public func seek(to time: TimeInterval) {
        let target = clampedSeekTime(time)
        apply(.userSeek(generation: commandGate.generation, position: target))
        playerState.vm.seek(to: target)
        persistCurrentPosition(force: true, position: target)
    }

    public func commitScrubbing() {
        let resume = wasPlayingBeforeScrub
        let target = playerState.vm.scrubTime
        wasPlayingBeforeScrub = false
        apply(.userSeek(generation: commandGate.generation, position: target))
        playerState.vm.commitAudioFirstScrub(resumeAfterSeek: resume)
        persistCurrentPosition(force: true, position: target)
    }

    public var playbackBufferedProgress: Double {
        guard playerState.vm.duration.isFinite, playerState.vm.duration > 0,
              let ranges = playerState.vm.player.currentItem?.loadedTimeRanges else { return 0 }
        let furthest = ranges.map { $0.timeRangeValue.end.seconds }
            .filter(\.isFinite)
            .max() ?? 0
        return min(1, max(0, furthest / playerState.vm.duration))
    }

    private func completedLocalEntry(for video: Video) -> DownloadedVideo? {
        if let kind = video.localMediaKind,
           let exact = DownloadStore.shared.entry(videoId: video.id, kind: kind),
           exact.status == .completed {
            return exact
        }
        return DownloadStore.shared.entry(videoId: video.id, kind: .audio).flatMap {
            $0.status == .completed ? $0 : nil
        } ?? DownloadStore.shared.entry(videoId: video.id, kind: .video).flatMap {
            $0.status == .completed ? $0 : nil
        }
    }

    private func openLocal(_ entry: DownloadedVideo, generation: UInt64) async {
        do {
            AudioDiagnostics.shared.record(
                source: "audio-first",
                event: "local.validate.begin",
                decision: entry.kind.rawValue,
                player: playerState.vm.player,
                itemID: entry.videoId,
                commandGeneration: generation
            )
            let item = try await playerState.validatedLocalAudioItem(for: entry.video)
            guard commandGate.isCurrent(generation), currentVideo?.id == entry.videoId,
                  !Task.isCancelled else { return }
            playerState.playAudioFirstLocal(video: entry.video, item: item)
            loadLocalCaptionMetadata(video: entry.video, generation: generation)
            synchronizeLiveActivity(force: true)
            apply(.playbackInstalled(generation: generation))
            apply(.completed(generation: generation))
            bufferedProgress = 1
            AudioDiagnostics.shared.record(
                source: "audio-first",
                event: "local.player.installed",
                decision: "firstTapReady",
                player: playerState.vm.player,
                itemID: entry.videoId,
                commandGeneration: generation
            )
            monitorTimelineAdvance(for: entry.video, generation: generation)
        } catch {
            guard commandGate.isCurrent(generation) else { return }
            apply(.exhaustedFailure(generation: generation, message: error.localizedDescription))
            DownloadStore.shared.update(
                videoId: entry.videoId,
                kind: entry.kind,
                status: .failed,
                progress: entry.progress,
                errorMessage: error.localizedDescription
            )
            AudioDiagnostics.shared.record(
                source: "audio-first",
                event: "local.validate.failed",
                decision: entry.kind.rawValue,
                player: playerState.vm.player,
                itemID: entry.videoId,
                commandGeneration: generation,
                error: error
            )
            detachUnplayableNowPlaying(video: entry.video, generation: generation)
        }
    }

    private func resolveAndStart(video: Video, generation: UInt64) async {
        do {
            let resolved = try await resolveDownloadPlan(for: video)
            markTiming("metadata-resolved")
            guard commandGate.isCurrent(generation), currentVideo?.id == video.id, !Task.isCancelled else { return }
            if OfflineAudioFormatSelector.supportsInstantPlayback(resolved.plan),
               let url = resolved.plan.format.url {
                try startSparsePlayback(
                    video: video,
                    plan: resolved.plan,
                    source: .init(
                        url: url,
                        userAgent: resolved.userAgent,
                        fingerprint: SparseSourceFingerprint(
                            videoID: video.id,
                            profile: Self.representationProfile(plan: resolved.plan, format: resolved.plan.format),
                            mimeType: resolved.plan.format.mimeType
                        ),
                        legacyProfile: Self.legacyRepresentationProfile(plan: resolved.plan, format: resolved.plan.format)
                    ),
                    captionTracks: resolved.captionTracks,
                    generation: generation
                )
            } else {
                await runFullPreparationFallback(
                    video: video,
                    captionTracks: resolved.captionTracks,
                    generation: generation
                )
            }
        } catch is CancellationError {
            return
        } catch {
            fail(video: video, error: error, generation: generation)
        }
    }

    private struct ResolvedAudioPlan {
        let plan: OfflineAudioDownloadPlan
        let userAgent: String
        let captionTracks: [CaptionTrack]
    }

    private func resolveDownloadPlan(for video: Video) async throws -> ResolvedAudioPlan {
        var resolvedFormats: [VideoFormat] = []
        var resolvedCaptionTracks: [CaptionTrack] = []
        var resolutionErrors: [Error] = []
        var androidFormatCount = 0
        var vrFormatCount = 0

        do {
            let android = try await api.fetchPlayerInfoAndroid(videoId: video.id)
            androidFormatCount = android.formats.count
            resolvedFormats.append(contentsOf: android.formats)
            resolvedCaptionTracks = Self.mergedCaptionTracks(
                resolvedCaptionTracks,
                android.captionTracks
            )
            if let plan = OfflineAudioFormatSelector.select(from: android.formats) {
                return ResolvedAudioPlan(
                    plan: plan,
                    userAgent: InnerTubeClients.Android.userAgent,
                    captionTracks: resolvedCaptionTracks
                )
            }
        } catch {
            resolutionErrors.append(error)
            AudioDiagnostics.shared.record(
                source: "audio-source-resolution",
                event: "client.failed",
                decision: "client=android class=\(OfflineFailurePresentationPolicy.reason(for: error)?.rawValue ?? "unknown")",
                player: playerState.vm.player,
                itemID: video.id,
                commandGeneration: commandGate.generation,
                error: error
            )
        }

        // A LOGIN_REQUIRED response from the Android client is frequently a bot check,
        // not a content restriction. Always let the independent AndroidVR client try
        // before presenting a terminal error.
        do {
            let vr = try await api.fetchPlayerInfoAndroidVR(videoId: video.id)
            resolvedFormats.append(contentsOf: vr.formats)
            resolvedCaptionTracks = Self.mergedCaptionTracks(
                resolvedCaptionTracks,
                vr.captionTracks
            )
            vrFormatCount = vr.formats.count
            if let plan = OfflineAudioFormatSelector.select(from: vr.formats) {
                return ResolvedAudioPlan(
                    plan: plan,
                    userAgent: InnerTubeClients.AndroidVR.userAgent,
                    captionTracks: resolvedCaptionTracks
                )
            }
        } catch {
            resolutionErrors.append(error)
            AudioDiagnostics.shared.record(
                source: "audio-source-resolution",
                event: "client.failed",
                decision: "client=android-vr class=\(OfflineFailurePresentationPolicy.reason(for: error)?.rawValue ?? "unknown")",
                player: playerState.vm.player,
                itemID: video.id,
                commandGeneration: commandGate.generation,
                error: error
            )
        }

        if resolvedFormats.isEmpty, !resolutionErrors.isEmpty {
            let priority: [OfflineFailureReason] = [
                .ageRestricted,
                .regionRestricted,
                .botChallenge,
                .transientNetwork,
                .resolverFailure,
                .loginRequired,
                .unavailable,
                .signInRequired,
            ]
            for reason in priority {
                if let error = resolutionErrors.first(where: {
                    OfflineFailurePresentationPolicy.reason(for: $0) == reason
                }) {
                    throw error
                }
            }
            throw resolutionErrors[0]
        }

        let reason = OfflineAudioFormatSelector.unsupportedReason(for: resolvedFormats)
        let failure = AudioSourceResolutionFailure.unsupportedFormats
        let error = Self.sourceResolutionError(failure, reason: reason)
        AudioDiagnostics.shared.record(
            source: "audio-source-resolution",
            event: "format.unsupported",
            decision: "code=\(failure.diagnosticCode) android=\(androidFormatCount) vr=\(vrFormatCount)",
            player: playerState.vm.player,
            itemID: video.id,
            commandGeneration: commandGate.generation,
            error: error
        )
        throw error
    }

    nonisolated private static func mergedCaptionTracks(
        _ existing: [CaptionTrack],
        _ additional: [CaptionTrack]
    ) -> [CaptionTrack] {
        var seen = Set(existing.map(\.id))
        return existing + additional.filter { seen.insert($0.id).inserted }
    }

    nonisolated private static func sourceResolutionError(
        _ failure: AudioSourceResolutionFailure,
        reason: String? = nil
    ) -> NSError {
        let message: String
        switch failure {
        case .unsupportedFormats:
            switch reason {
            case "Audio formats were returned, but YouTube did not provide a downloadable URL.":
                message = String(localized: "Audio formats were returned, but YouTube did not provide a downloadable URL.", bundle: .module)
            case "Only WebM/Opus audio is downloadable, and iOS cannot export that container with AVFoundation.":
                message = String(localized: "Only WebM/Opus audio is downloadable, and iOS cannot export that container with AVFoundation.", bundle: .module)
            case "The available audio format cannot be decoded by iOS.":
                message = String(localized: "The available audio format cannot be decoded by iOS.", bundle: .module)
            default:
                message = String(localized: "No downloadable audio or compatible MP4 video stream was returned.", bundle: .module)
            }
        case .selectedURLMissing:
            message = String(localized: "YouTube did not provide a downloadable URL for the selected audio format.", bundle: .module)
        case .unsupportedPlaybackPlan:
            message = String(localized: "The available audio format cannot be decoded by iOS.", bundle: .module)
        }
        return NSError(
            domain: AudioSourceResolutionFailure.errorDomain,
            code: failure.rawValue,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }

    private func startSparsePlayback(
        video: Video,
        plan: OfflineAudioDownloadPlan,
        source: ProgressiveAudioResourceLoader.Source,
        captionTracks: [CaptionTrack],
        generation: UInt64
    ) throws {
        apply(.buffering(generation: generation))
        currentPlan = plan
        markTiming("format-chosen", details: "source=\(plan.source.rawValue) mime=\(plan.format.mimeType)")
        DownloadStore.shared.update(videoId: video.id, kind: .audio, status: .downloading, progress: 0.05)

        let loaderID = UUID()
        let loader = try ProgressiveAudioResourceLoader(
            id: loaderID,
            source: source,
            videoId: video.id,
            mimeType: plan.format.mimeType,
            fileExtension: plan.downloadFileExtension,
            cacheDirectory: DownloadStore.shared.partialDownloadsDirectory,
            allowsCellularAccess: !settingsStore.settings.downloadsWiFiOnly,
            refreshSource: { [api, originalUserAgent = source.userAgent] in
                let refreshedInfo: PlayerInfo
                if originalUserAgent == InnerTubeClients.AndroidVR.userAgent {
                    refreshedInfo = try await api.fetchPlayerInfoAndroidVR(videoId: video.id)
                } else {
                    refreshedInfo = try await api.fetchPlayerInfoAndroid(videoId: video.id)
                }
                let candidates = refreshedInfo.formats.filter {
                    $0.mimeType == plan.format.mimeType && $0.url != nil
                }
                let refreshedFormat: VideoFormat?
                if let itag = plan.format.itag {
                    refreshedFormat = candidates.first { $0.itag == itag }
                } else {
                    refreshedFormat = candidates.first {
                        $0.bitrate == plan.format.bitrate
                    }
                }
                guard let refreshedFormat, let refreshedURL = refreshedFormat.url else {
                    throw URLError(.resourceUnavailable)
                }
                return .init(
                    url: refreshedURL,
                    userAgent: originalUserAgent,
                    fingerprint: SparseSourceFingerprint(
                        videoID: video.id,
                        profile: Self.representationProfile(plan: plan, format: refreshedFormat),
                        mimeType: refreshedFormat.mimeType
                    ),
                    legacyProfile: Self.legacyRepresentationProfile(plan: plan, format: refreshedFormat)
                )
            },
            progress: { [weak self] progress in
                Task { @MainActor [weak self] in
                    self?.receive(progress: progress, video: video, generation: generation, loaderID: loaderID)
                }
            },
            diagnostic: { [weak self] diagnostic in
                Task { @MainActor [weak self] in
                    self?.record(
                        diagnostic,
                        video: video,
                        generation: generation,
                        loaderID: loaderID
                    )
                }
            },
            completion: { [weak self] result in
                Task { @MainActor [weak self] in
                    await self?.completeProgressive(
                        result: result,
                        video: video,
                        generation: generation,
                        loaderID: loaderID,
                        plan: plan
                    )
                }
            }
        )
        resourceLoader = loader
        activeLoaderID = loaderID
        let asset = loader.makeAsset()
        let item = AVPlayerItem(asset: asset)
        item.audioTimePitchAlgorithm = .spectral
        item.preferredForwardBufferDuration = 0.5
        playerState.prepareProgressiveAudio(item: item, video: video)
        apply(.playbackInstalled(generation: generation))
        // AVPlayer now drives the first header/moov/media ranges itself. Starting
        // play here is essential: waiting for an arbitrary prefix recreates the
        // old full-download behavior for files whose index is at the tail.
        playerState.startPreparedAudioPlayback()
        applyPreparedAudioCaptions(
            captionTracks,
            video: video,
            generation: generation
        )
        synchronizeLiveActivity(force: true)
        loader.start()
        loader.startBackgroundFill()
        monitorTimelineAdvance(for: video, generation: generation)
    }

    private func receive(
        progress: ProgressiveAudioResourceLoader.Progress,
        video: Video,
        generation: UInt64,
        loaderID: UUID
    ) {
        guard commandGate.isCurrent(generation), activeLoaderID == loaderID,
              currentVideo?.id == video.id else { return }
        _ = playbackState.receive(
            downloaded: progress.downloadedBytes,
            expected: progress.expectedBytes
        )
        apply(.downloadProgress(generation: generation, value: playbackState.downloadProgress))
        bufferedProgress = playbackState.downloadProgress
        DownloadStore.shared.update(
            videoId: video.id,
            kind: .audio,
            status: .downloading,
            progress: downloadProgress,
            fileSizeBytes: progress.downloadedBytes
        )
    }

    private func completeProgressive(
        result: Result<ProgressiveAudioResourceLoader.Progress, Error>,
        video: Video,
        generation: UInt64,
        loaderID: UUID,
        plan: OfflineAudioDownloadPlan
    ) async {
        guard commandGate.isCurrent(generation), activeLoaderID == loaderID,
              currentVideo?.id == video.id else { return }
        switch result {
        case .failure(let error):
            if !scheduleProgressiveRecovery(
                video: video,
                error: error,
                generation: generation,
                loaderID: loaderID
            ) {
                fail(video: video, error: error, generation: generation)
            }
        case .success(let progress):
            milestones.downloadCompleted()
            _ = playbackState.finish(
                downloaded: progress.downloadedBytes,
                expected: progress.expectedBytes
            )
            do {
                guard commandGate.isCurrent(generation), activeLoaderID == loaderID,
                      let resourceLoader else { throw CancellationError() }
                let destination = DownloadStore.shared.destinationURL(for: video.id, kind: .audio)
                let bytes: Int64
                switch plan.source {
                case .directM4A:
                    // The final file replaces the matching sparse allocation via
                    // hard link/atomic install, so this is not an additional copy
                    // against the user's logical storage budget.
                    guard canStore(0) else { throw storageLimitError() }
                    bytes = try await resourceLoader.finalize(to: destination)
                    guard commandGate.isCurrent(generation), activeLoaderID == loaderID,
                          currentVideo?.id == video.id else { return }
                case .directNativeAudio, .muxedMP4Extraction:
                    // Playback continues from the completed sparse source while
                    // AVFoundation remuxes/exports the final offline M4A in background.
                    apply(.finalizationStarted(generation: generation))
                    milestones.exportBegan()
                    markTiming("export-start", details: "source=\(plan.source.rawValue)")
                    let sourceURL = try await resourceLoader.completedSourceURL()
                    let prepared = try await VideoDownloadService.extractAudioToM4A(
                        inputURL: sourceURL,
                        videoId: video.id
                    )
                    defer { try? FileManager.default.removeItem(at: prepared) }
                    guard commandGate.isCurrent(generation), activeLoaderID == loaderID,
                          currentVideo?.id == video.id else { return }
                    bytes = Int64((try? prepared.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                    guard bytes > 0 else { throw URLError(.zeroByteResource) }
                    guard canStore(bytes) else { throw storageLimitError() }
                    let staging = destination.appendingPathExtension("new")
                    try? FileManager.default.removeItem(at: staging)
                    try FileManager.default.copyItem(at: prepared, to: staging)
                    try atomicallyInstall(staging: staging, destination: destination)
                    markTiming("export-complete", details: "bytes=\(bytes)")
                }
                guard commandGate.isCurrent(generation), activeLoaderID == loaderID,
                      currentVideo?.id == video.id else { return }
                DownloadStore.shared.complete(video: video, kind: .audio, fileURL: destination, fileSizeBytes: bytes)
                apply(.completed(generation: generation))
                bufferedProgress = 1
            } catch {
                handleFinalizationFailure(
                    video: video,
                    error: error,
                    generation: generation,
                    verifiedBytes: progress.downloadedBytes
                )
            }
        }
    }

    private func resumeIncompleteAudio(
        _ entry: DownloadedVideo,
        reconciliationGeneration generation: UInt64
    ) async {
        defer {
            if reconciliationGeneration == generation {
                reconciliationTask = nil
                reconciliationVideoID = nil
            }
        }
        guard applicationIsActive, entry.kind == .audio,
              reconciliationGeneration == generation,
              reconciliationVideoID == entry.videoId,
              DownloadStore.shared.entry(videoId: entry.videoId, kind: .audio)?.shouldAutomaticallyResume == true,
              entry.videoId != currentVideo?.id else { return }
        do {
            let video = entry.video
            let resolved = try await resolveDownloadPlan(for: video)
            let plan = resolved.plan
            try Task.checkCancellation()
            guard applicationIsActive,
                  reconciliationGeneration == generation,
                  reconciliationVideoID == entry.videoId,
                  entry.videoId != currentVideo?.id,
                  DownloadStore.shared.entry(videoId: entry.videoId, kind: .audio)?.shouldAutomaticallyResume == true else {
                throw CancellationError()
            }
            guard let url = plan.format.url else {
                throw Self.sourceResolutionError(.selectedURLMissing)
            }
            guard OfflineAudioFormatSelector.supportsInstantPlayback(plan) else {
                throw Self.sourceResolutionError(.unsupportedPlaybackPlan)
            }

            let source = ProgressiveAudioResourceLoader.Source(
                url: url,
                userAgent: resolved.userAgent,
                fingerprint: SparseSourceFingerprint(
                    videoID: video.id,
                    profile: Self.representationProfile(plan: plan, format: plan.format),
                    mimeType: plan.format.mimeType
                ),
                legacyProfile: Self.legacyRepresentationProfile(plan: plan, format: plan.format)
            )
            let loaderID = UUID()
            let loader = try ProgressiveAudioResourceLoader(
                id: loaderID,
                source: source,
                videoId: video.id,
                mimeType: plan.format.mimeType,
                fileExtension: plan.downloadFileExtension,
                cacheDirectory: DownloadStore.shared.partialDownloadsDirectory,
                allowsCellularAccess: !settingsStore.settings.downloadsWiFiOnly,
                refreshSource: { [api, originalUserAgent = source.userAgent] in
                    let info = originalUserAgent == InnerTubeClients.AndroidVR.userAgent
                        ? try await api.fetchPlayerInfoAndroidVR(videoId: video.id)
                        : try await api.fetchPlayerInfoAndroid(videoId: video.id)
                    let formats = info.formats.filter { $0.mimeType == plan.format.mimeType && $0.url != nil }
                    let refreshed = plan.format.itag.flatMap { itag in formats.first { $0.itag == itag } }
                        ?? formats.first { $0.bitrate == plan.format.bitrate }
                    guard let refreshed, let refreshedURL = refreshed.url else {
                        throw URLError(.resourceUnavailable)
                    }
                    return .init(
                        url: refreshedURL,
                        userAgent: originalUserAgent,
                        fingerprint: SparseSourceFingerprint(
                            videoID: video.id,
                            profile: Self.representationProfile(plan: plan, format: refreshed),
                            mimeType: refreshed.mimeType
                        ),
                        legacyProfile: Self.legacyRepresentationProfile(plan: plan, format: refreshed)
                    )
                },
                progress: { progress in
                    Task { @MainActor [weak self] in
                        self?.receiveSupervised(progress, video: video, loaderID: loaderID)
                    }
                },
                diagnostic: { diagnostic in
                    Task { @MainActor [weak self] in
                        self?.recordSupervised(diagnostic, video: video, loaderID: loaderID)
                    }
                },
                completion: { result in
                    Task { @MainActor [weak self] in
                        await self?.completeSupervised(result, video: video, plan: plan, loaderID: loaderID)
                    }
                }
            )
            try Task.checkCancellation()
            guard reconciliationGeneration == generation,
                  reconciliationVideoID == entry.videoId,
                  entry.videoId != currentVideo?.id else { throw CancellationError() }
            supervisedLoader = loader
            supervisedLoaderID = loaderID
            supervisedVideoID = video.id
            DownloadStore.shared.update(
                videoId: video.id,
                kind: .audio,
                status: .reconnecting,
                progress: entry.progress,
                errorMessage: String(localized: "Resuming automatically…", bundle: .module),
                resumePolicy: .automatic
            )
            loader.start()
            loader.startBackgroundFill(after: .zero)
        } catch is CancellationError {
            return
        } catch {
            handleSupervisedFailure(error, video: entry.video)
        }
    }

    private func receiveSupervised(
        _ progress: ProgressiveAudioResourceLoader.Progress,
        video: Video,
        loaderID: UUID
    ) {
        guard supervisedLoaderID == loaderID, supervisedVideoID == video.id else { return }
        let fraction = progress.expectedBytes > 0
            ? Double(progress.downloadedBytes) / Double(progress.expectedBytes)
            : DownloadStore.shared.entry(videoId: video.id, kind: .audio)?.progress ?? 0
        DownloadStore.shared.update(
            videoId: video.id,
            kind: .audio,
            status: .downloading,
            progress: fraction,
            fileSizeBytes: progress.downloadedBytes,
            resumePolicy: .automatic
        )
    }

    private func recordSupervised(
        _ diagnostic: ProgressiveAudioResourceLoader.Diagnostic,
        video: Video,
        loaderID: UUID
    ) {
        guard supervisedLoaderID == loaderID, supervisedVideoID == video.id else { return }
        if diagnostic.stage == "waiting-wifi" {
            DownloadStore.shared.update(
                videoId: video.id,
                kind: .audio,
                status: .waitingForWiFi,
                progress: DownloadStore.shared.entry(videoId: video.id, kind: .audio)?.progress ?? 0,
                errorMessage: String(localized: "Waiting for Wi-Fi", bundle: .module),
                resumePolicy: .automatic
            )
        } else if diagnostic.stage.hasPrefix("retry-backoff") || diagnostic.stage.hasPrefix("validator-retry") {
            DownloadStore.shared.update(
                videoId: video.id,
                kind: .audio,
                status: .reconnecting,
                progress: DownloadStore.shared.entry(videoId: video.id, kind: .audio)?.progress ?? 0,
                errorMessage: String(localized: "Reconnecting…", bundle: .module),
                resumePolicy: .automatic
            )
        }
        if diagnostic.stage == "first-response" || diagnostic.stage.hasPrefix("http-") {
            let status = diagnostic.statusCode.map(String.init) ?? "-"
            AudioDiagnostics.shared.record(
                source: "download-supervisor",
                event: diagnostic.stage,
                decision: "status=\(status) type=\(diagnostic.contentType ?? "-") encoding=\(diagnostic.contentEncoding ?? "-") body=\(diagnostic.bodyClass ?? "-")",
                player: playerState.vm.player,
                itemID: video.id
            )
        }
    }

    private func completeSupervised(
        _ result: Result<ProgressiveAudioResourceLoader.Progress, Error>,
        video: Video,
        plan: OfflineAudioDownloadPlan,
        loaderID: UUID
    ) async {
        guard supervisedLoaderID == loaderID, supervisedVideoID == video.id,
              let loader = supervisedLoader else { return }
        switch result {
        case .failure(let error):
            clearSupervisedDownload(discardCache: false)
            handleSupervisedFailure(error, video: video)
        case .success(let progress):
            do {
                let destination = DownloadStore.shared.destinationURL(for: video.id, kind: .audio)
                let bytes: Int64
                switch plan.source {
                case .directM4A:
                    guard canStore(0) else { throw storageLimitError() }
                    bytes = try await loader.finalize(to: destination)
                case .directNativeAudio, .muxedMP4Extraction:
                    let sourceURL = try await loader.completedSourceURL()
                    let prepared = try await VideoDownloadService.extractAudioToM4A(
                        inputURL: sourceURL,
                        videoId: video.id
                    )
                    defer { try? FileManager.default.removeItem(at: prepared) }
                    bytes = Int64((try? prepared.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                    guard bytes > 0 else { throw URLError(.zeroByteResource) }
                    guard canStore(bytes) else { throw storageLimitError() }
                    let staging = destination.appendingPathExtension("new")
                    try? FileManager.default.removeItem(at: staging)
                    try FileManager.default.copyItem(at: prepared, to: staging)
                    try atomicallyInstall(staging: staging, destination: destination)
                }
                DownloadStore.shared.complete(video: video, kind: .audio, fileURL: destination, fileSizeBytes: bytes)
                clearSupervisedDownload(discardCache: true)
                reconcileDownloads(trigger: "job-completed")
            } catch {
                clearSupervisedDownload(discardCache: false)
                handleSupervisedFailure(error, video: video)
            }
        }
    }

    private func handleSupervisedFailure(_ error: Error, video: Video) {
        let entry = DownloadStore.shared.entry(videoId: video.id, kind: .audio)
        let nextRetry = (entry?.retryCount ?? 0) + 1
        if Self.isTransientDownloadFailure(error), nextRetry <= 6 {
            DownloadStore.shared.update(
                videoId: video.id,
                kind: .audio,
                status: .reconnecting,
                progress: entry?.progress ?? 0,
                errorMessage: String(localized: "Reconnecting…", bundle: .module),
                retryCount: nextRetry,
                resumePolicy: .automatic
            )
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(min(30, 1 << min(nextRetry, 5))))
                guard !Task.isCancelled else { return }
                await MainActor.run { self?.reconcileDownloads(trigger: "bounded-retry") }
            }
        } else {
            let failureReason = OfflineFailurePresentationPolicy.reason(for: error)
            let message = failureReason.map(OfflineFailurePresentationPolicy.message(for:))
                ?? error.localizedDescription
            DownloadStore.shared.update(
                videoId: video.id,
                kind: .audio,
                status: .failed,
                progress: entry?.progress ?? 0,
                errorMessage: message,
                failureReason: failureReason,
                retryCount: nextRetry,
                resumePolicy: .manual
            )
        }
        AudioDiagnostics.shared.record(
            source: "download-supervisor",
            event: "reconcile.failed",
            decision: Self.isTransientDownloadFailure(error) ? "retryable" : "terminal",
            player: playerState.vm.player,
            itemID: video.id,
            error: error
        )
    }

    private func startReconciliationWatchdog() {
        guard reconciliationWatchdogTask == nil else { return }
        reconciliationWatchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                guard !Task.isCancelled else { return }
                await MainActor.run { self?.reconcileDownloads(trigger: "foreground-watchdog") }
            }
        }
    }

    private func cancelSupervisedDownload(ifMatching videoID: String) {
        var claimedOwnership = false
        if reconciliationVideoID == videoID {
            reconciliationGeneration &+= 1
            reconciliationTask?.cancel()
            reconciliationTask = nil
            reconciliationVideoID = nil
            claimedOwnership = true
        }
        if supervisedVideoID == videoID {
            supervisedLoader?.cancel(discardCache: false)
            clearSupervisedDownload(discardCache: false)
            claimedOwnership = true
        }
        guard claimedOwnership else { return }
        if let entry = DownloadStore.shared.entry(videoId: videoID, kind: .audio) {
            DownloadStore.shared.update(
                videoId: videoID,
                kind: .audio,
                status: .paused,
                progress: entry.progress,
                errorMessage: String(localized: "Resuming automatically…", bundle: .module),
                resumePolicy: .automatic
            )
        }
    }

    private func clearSupervisedDownload(discardCache: Bool) {
        if discardCache {
            supervisedLoader?.cancel(discardCache: true)
        }
        supervisedLoader = nil
        supervisedLoaderID = nil
        supervisedVideoID = nil
    }

    nonisolated private static func isTransientDownloadFailure(_ error: Error) -> Bool {
        if ProgressiveAudioResourceLoader.isRetryableFailure(error) { return true }
        let code = (error as? URLError)?.code
        return code == .timedOut || code == .cannotFindHost || code == .cannotConnectToHost
            || code == .networkConnectionLost || code == .dnsLookupFailed || code == .notConnectedToInternet
            || code == .resourceUnavailable || code == .internationalRoamingOff
            || code == .dataNotAllowed
    }

    private func runFullPreparationFallback(
        video: Video,
        captionTracks: [CaptionTrack],
        generation: UInt64
    ) async {
        apply(.finalizationStarted(generation: generation))
        // The coordinator owns the progressive placeholder. The legacy fallback
        // owns its own lifecycle and must re-register the same logical item so it
        // can resolve a fresh URL and complete it without creating a duplicate.
        if DownloadStore.shared.entry(videoId: video.id, kind: .audio)?.status.isActive == true {
            DownloadStore.shared.remove(videoId: video.id, kind: .audio)
        }
        fallbackService.reset()
        fallbackService.download(
            video: video,
            kind: .audio,
            saveVideoToPhotos: false,
            storageLimitMB: settingsStore.settings.offlineStorageLimitMB
        )

        while !Task.isCancelled, commandGate.isCurrent(generation), currentVideo?.id == video.id {
            switch fallbackService.state {
            case .done:
                guard let entry = DownloadStore.shared.entry(videoId: video.id, kind: .audio),
                      entry.status == .completed else {
                    fail(video: video, error: URLError(.fileDoesNotExist), generation: generation)
                    return
                }
                do {
                    let item = try await playerState.validatedLocalAudioItem(for: entry.video)
                    guard commandGate.isCurrent(generation) else { return }
                    playerState.playAudioFirstLocal(video: entry.video, item: item)
                    applyPreparedAudioCaptions(
                        captionTracks,
                        video: video,
                        generation: generation
                    )
                    synchronizeLiveActivity(force: true)
                    apply(.playbackInstalled(generation: generation))
                    apply(.completed(generation: generation))
                    bufferedProgress = 1
                } catch {
                    fail(video: video, error: error, generation: generation)
                }
                fallbackService.reset()
                return
            case .failed(let message):
                fail(
                    video: video,
                    error: NSError(domain: "iPocketTubeOffline", code: 4, userInfo: [NSLocalizedDescriptionKey: message]),
                    generation: generation
                )
                fallbackService.reset()
                return
            case .downloading(let progress):
                apply(.downloadProgress(generation: generation, value: progress))
            case .saving:
                apply(.downloadProgress(generation: generation, value: 0.9))
            case .fetching:
                apply(.downloadProgress(generation: generation, value: 0.05))
            case .idle:
                break
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    @discardableResult
    private func scheduleProgressiveRecovery(
        video: Video,
        error: Error,
        generation: UInt64,
        loaderID: UUID
    ) -> Bool {
        guard commandGate.isCurrent(generation), activeLoaderID == loaderID,
              currentVideo?.id == video.id,
              Self.isTransientDownloadFailure(error) else { return false }
        let entry = DownloadStore.shared.entry(videoId: video.id, kind: .audio)
        let retry = (entry?.retryCount ?? 0) + 1
        guard retry <= 3 else { return false }

        resourceLoader?.cancel(discardCache: false)
        resourceLoader = nil
        activeLoaderID = nil
        apply(.reconnecting(generation: generation))
        DownloadStore.shared.update(
            videoId: video.id,
            kind: .audio,
            status: .reconnecting,
            progress: entry?.progress ?? downloadProgress,
            errorMessage: String(localized: "Reconnecting…", bundle: .module),
            retryCount: retry,
            resumePolicy: .automatic
        )
        AudioDiagnostics.shared.record(
            source: "audio-first",
            event: "range.recovery.scheduled",
            decision: "attempt=\(retry)",
            player: playerState.vm.player,
            itemID: video.id,
            commandGeneration: generation,
            error: error
        )
        workTask?.cancel()
        workTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(
                SparseDownloadRetryPolicy.delayMilliseconds(attempt: retry - 1, seed: 0)
            ))
            guard let self, !Task.isCancelled,
                  self.commandGate.isCurrent(generation),
                  self.currentVideo?.id == video.id else { return }
            await self.resolveAndStart(video: video, generation: generation)
        }
        return true
    }

    private func fail(video: Video, error: Error, generation: UInt64) {
        guard commandGate.isCurrent(generation), currentVideo?.id == video.id else { return }
        let failureReason = OfflineFailurePresentationPolicy.reason(for: error)
        let message = failureReason.map(OfflineFailurePresentationPolicy.message(for:))
            ?? error.localizedDescription
        guard apply(.exhaustedFailure(generation: generation, message: message)) else { return }
        if let state = ttfaSignpostState {
            signposter.endInterval("TapToFirstTimeline", state)
            ttfaSignpostState = nil
        }
        let preservedProgress = DownloadStore.shared.entry(videoId: video.id, kind: .audio)?.progress ?? downloadProgress
        let remainsPlayable = authoritativeState.hasPlayableSource
        DownloadStore.shared.update(
            videoId: video.id,
            kind: .audio,
            status: remainsPlayable ? .paused : .failed,
            progress: preservedProgress,
            errorMessage: message,
            failureReason: failureReason,
            resumePolicy: .manual
        )
        AudioDiagnostics.shared.record(
            source: "audio-first",
            event: "command.failed",
            decision: String(describing: type(of: error)),
            player: playerState.vm.player,
            itemID: video.id,
            commandGeneration: generation,
            error: error
        )
        if AudioFirstTerminalPresentationPolicy.shouldDetachNowPlaying(hasPlayableSource: remainsPlayable) {
            detachUnplayableNowPlaying(video: video, generation: generation)
        }
    }

    private func detachUnplayableNowPlaying(video: Video, generation: UInt64) {
        guard commandGate.isCurrent(generation), currentVideo?.id == video.id else { return }
        AudioDiagnostics.shared.record(
            source: "audio-first",
            event: "nowPlaying.detached",
            decision: "terminal-no-playable-source",
            player: playerState.vm.player,
            itemID: video.id,
            commandGeneration: generation
        )
        pendingHistoryActivation = nil
        playbackLiveActivity.stop()
        cancelActiveWork(markCancelled: false, stopPlayer: true)
        _ = commandGate.advance()
        currentVideo = nil
        apply(.close)
        bufferedProgress = 0
    }

    private func handleFinalizationFailure(
        video: Video,
        error: Error,
        generation: UInt64,
        verifiedBytes: Int64
    ) {
        guard commandGate.isCurrent(generation), currentVideo?.id == video.id,
              apply(.finalizationFailed(generation: generation, message: error.localizedDescription)) else { return }
        DownloadStore.shared.update(
            videoId: video.id,
            kind: .audio,
            status: authoritativeState.hasPlayableSource ? .finalizationPending : .failed,
            progress: 1,
            errorMessage: error.localizedDescription,
            fileSizeBytes: verifiedBytes
        )
        AudioDiagnostics.shared.record(
            source: "audio-first",
            event: "finalization.failed",
            decision: authoritativeState.hasPlayableSource ? "sparsePlayable" : "noPlayableSource",
            player: playerState.vm.player,
            itemID: video.id,
            commandGeneration: generation,
            error: error
        )
    }

    private func close(markCancelled: Bool) {
        persistCurrentPosition(force: true)
        _ = commandGate.advance()
        pendingHistoryActivation = nil
        pendingDubbingVideoID = nil
        pendingDubbingSourceLanguageOverride = nil
        playerState.vm.localDubbingManager.cancel(clearResult: true)
        transcriptSummary.reset()
        playbackLiveActivity.stop()
        cancelActiveWork(markCancelled: markCancelled, stopPlayer: true)
        currentVideo = nil
        apply(.close)
        bufferedProgress = 0
    }

    private func cancelActiveWork(markCancelled: Bool, stopPlayer: Bool) {
        let video = currentVideo
        if let state = ttfaSignpostState {
            signposter.endInterval("TapToFirstTimeline", state)
            ttfaSignpostState = nil
        }
        workTask?.cancel()
        workTask = nil
        timelineTask?.cancel()
        timelineTask = nil
        positionHydrationTask?.cancel()
        positionHydrationTask = nil
        captionMetadataTask?.cancel()
        captionMetadataTask = nil
        captionIdentity = nil
        playerState.vm.captionsManager.cancel()
        let completedCurrentAudio = video.flatMap {
            DownloadStore.shared.entry(videoId: $0.id, kind: .audio)
        }?.status == .completed
        resourceLoader?.cancel(discardCache: markCancelled || completedCurrentAudio)
        resourceLoader = nil
        activeLoaderID = nil
        currentPlan = nil
        fallbackService.cancel()
        fallbackService.reset()
        if markCancelled, let video,
           DownloadStore.shared.entry(videoId: video.id, kind: .audio)?.status.isActive == true {
            DownloadStore.shared.update(
                videoId: video.id,
                kind: .audio,
                status: .cancelled,
                progress: DownloadStore.shared.entry(videoId: video.id, kind: .audio)?.progress ?? downloadProgress,
                errorMessage: String(localized: "Download cancelled.", bundle: .module),
                resumePolicy: .manual
            )
        } else if let video,
                  DownloadStore.shared.entry(videoId: video.id, kind: .audio)?.status.isActive == true {
            DownloadStore.shared.update(
                videoId: video.id,
                kind: .audio,
                status: .paused,
                progress: DownloadStore.shared.entry(videoId: video.id, kind: .audio)?.progress ?? downloadProgress,
                errorMessage: String(localized: "Resuming automatically…", bundle: .module),
                resumePolicy: .automatic
            )
        }
        if stopPlayer { playerState.stop() }
    }

    private func monitorTimelineAdvance(for video: Video, generation: UInt64) {
        timelineTask?.cancel()
        timelineTask = Task { [weak self] in
            var recordedFirstAdvance = false
            while !Task.isCancelled {
                guard let self, self.commandGate.isCurrent(generation),
                      self.currentVideo?.id == video.id else { return }
                let seconds = self.playerState.vm.player.currentTime().seconds
                self.synchronizeLiveActivity(force: false)
                if seconds.isFinite, seconds >= 0.05 {
                    self.apply(.timeline(generation: generation, position: seconds))
                    self.persistCurrentPosition(force: false, position: seconds)
                    if let pending = self.pendingHistoryActivation,
                       pending.videoID == video.id,
                       pending.generation == generation,
                       self.playerState.vm.isPlaying {
                        DownloadStore.shared.markPlaybackActivated(
                            videoId: pending.videoID,
                            kind: pending.kind
                        )
                        self.pendingHistoryActivation = nil
                    }
                    if !recordedFirstAdvance {
                        recordedFirstAdvance = true
                        let elapsed = self.elapsedMilliseconds
                        self.milestones.timelineAdvanced()
                        self.lastTTFAMilliseconds = elapsed
                        if let state = self.ttfaSignpostState {
                            self.signposter.endInterval("TapToFirstTimeline", state)
                            self.ttfaSignpostState = nil
                        }
                        self.markTiming("timeline-advance", details: "download=\(Int(self.downloadProgress * 100))%")
                        AudioDiagnostics.shared.record(
                            source: "audio-first",
                            event: "timeline.firstAdvance",
                            decision: "download=\(Int(self.downloadProgress * 100))pct",
                            player: self.playerState.vm.player,
                            itemID: video.id,
                            commandGeneration: generation
                        )
                    }
                }
                try? await Task.sleep(for: .milliseconds(recordedFirstAdvance ? 200 : 50))
            }
        }
    }

    private func synchronizeLiveActivity(force: Bool) {
        guard let video = currentVideo, playerState.vm.player.currentItem != nil else { return }
        if let book = playerState.vm.captionsManager.transcriptBookResult?.document {
            transcriptSummary.prepareIfNeeded(document: book)
        }
        playbackLiveActivity.update(
            video: video,
            isPlaying: playerState.vm.isPlaying,
            elapsed: playerState.vm.currentTime,
            duration: playerState.vm.duration > 0 ? playerState.vm.duration : (video.duration ?? 0),
            transcriptLine: playerState.vm.currentCaptionCue?.text,
            force: force
        )
    }

    private func applyPreparedAudioCaptions(
        _ tracks: [CaptionTrack],
        video: Video,
        generation: UInt64
    ) {
        guard commandGate.isCurrent(generation),
              currentVideo?.id == video.id,
              let captionIdentity,
              captionIdentity.itemID == video.id else { return }
        _ = playerState.vm.applyPreparedAudioCaptions(
            tracks,
            identity: captionIdentity
        )
    }

    public func refreshLocalTranscriptionSetting() {
        // Local ASR is no longer a product path. YouTube captions and the
        // on-device EN to RU Translation owner are wired through CaptionsManager.
    }

    private func prepareLocalTranscriptionFallback(
        video: Video,
        generation: UInt64,
        identity: CaptionPlaybackIdentity
    ) {
        guard commandGate.isCurrent(generation), currentVideo?.id == video.id else { return }
        let eligibility = localTranscriptionEligibility()
        guard playerState.vm.prepareLocalTranscriptFallback(
            identity: identity,
            eligibility: eligibility
        ), eligibility == .allowed else { return }
        guard let audioURL = completedLocalAudioURL(for: video.id) else { return }
        startLocalTranscriptionIfReady(
            video: video,
            audioURL: audioURL,
            generation: generation
        )
    }

    private func startLocalTranscriptionIfReady(
        video: Video,
        audioURL: URL,
        generation: UInt64
    ) {
        guard commandGate.isCurrent(generation),
              currentVideo?.id == video.id,
              let captionIdentity,
              captionIdentity.itemID == video.id,
              FileManager.default.fileExists(atPath: audioURL.path) else { return }
        let localeIdentifier = settingsStore.settings.preferredCaptionLanguage
            ?? settingsStore.settings.preferredAudioLanguage
            ?? Locale.preferredLanguages.first
            ?? "ru-RU"
        _ = playerState.vm.startLocalTranscriptFallback(
            request: LocalTranscriptRequest(
                videoID: video.id,
                audioURL: audioURL,
                localeIdentifier: localeIdentifier
            ),
            identity: captionIdentity
        )
    }

    private func startRussianDubbing(
        video: Video,
        audioURL: URL,
        sourceLanguageOverride: String? = nil
    ) {
        guard currentVideo?.id == video.id,
              FileManager.default.fileExists(atPath: audioURL.path) else { return }
        pendingDubbingVideoID = nil
        pendingDubbingSourceLanguageOverride = nil
        playerState.vm.localDubbingManager.start(
            request: russianDubbingRequest(
                video: video,
                audioURL: audioURL,
                sourceLanguageOverride: sourceLanguageOverride
            )
        )
    }

    private func resumeRussianDubbingIfNeeded(video: Video, audioURL: URL) {
        let request = russianDubbingRequest(video: video, audioURL: audioURL)
        Task { [weak self] in
            guard let self, self.currentVideo?.id == video.id else { return }
            await self.playerState.vm.localDubbingManager.resumeIfAvailable(request: request)
        }
    }

    private func russianDubbingRequest(
        video: Video,
        audioURL: URL,
        sourceLanguageOverride: String? = nil
    ) -> LocalDubbingRequest {
        let captions = playerState.vm.captionsManager
        let smokeDuration = Self.dubbingSmokeDuration
        let russianFixture = Self.dubbingRussianFixture
        let requestVideoID = smokeDuration.map {
            "\(video.id)-physical-smoke-\(Int($0))\(russianFixture ? "-ru-fixture" : "")"
        } ?? video.id
        let selectedLanguage = captions.selectedCaption?.languageCode
        let effectiveOverride = sourceLanguageOverride
            ?? (russianFixture ? "ru" : nil)
        let sourceOrigin: LocalDubbingTranscriptOrigin? = switch captions.transcriptSource {
        case .youtubeCaptions: .youtubeCaptions
        case .localSpeech:
            captions.localTranscriptEngine == .speechAnalyzer ? .speechAnalyzer : .parakeet
        default: nil
        }
        return LocalDubbingRequest(
            videoID: requestVideoID,
            title: video.title,
            sourceAudioURL: audioURL,
            availableSourceCues: russianFixture
                ? Self.russianDubbingFixtureCues
                : (captions.transcriptState == .ready ? captions.captionCues : []),
            availableSourceOrigin: russianFixture ? .youtubeCaptions : sourceOrigin,
            sourceCaptionLanguageCode: russianFixture
                ? "ru"
                : (captions.transcriptSource == .youtubeCaptions ? selectedLanguage : nil),
            sourceLanguageOverride: effectiveOverride,
            maximumSourceDuration: smokeDuration
        )
    }

    private static var dubbingSmokeDuration: TimeInterval? {
        let prefix = "--uitesting-dubbing-smoke-seconds="
        guard let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix(prefix) }),
              let seconds = TimeInterval(argument.dropFirst(prefix.count)),
              (10...120).contains(seconds) else { return nil }
        return seconds
    }

    private static var dubbingAutoStart: Bool {
        ProcessInfo.processInfo.arguments.contains("--uitesting-dubbing-auto-start")
    }

    private static var dubbingRussianFixture: Bool {
        ProcessInfo.processInfo.arguments.contains("--uitesting-dubbing-russian-fixture")
    }

    private static let russianDubbingFixtureCues: [CaptionCue] = (0..<15).map { index in
        let start = TimeInterval(index * 4)
        return CaptionCue(
            startTime: start,
            endTime: start + 3.5,
            text: "Проверочная русская реплика номер \(index + 1), она сохраняет абсолютный временной код и готовый сегмент."
        )
    }

    private func completedLocalAudioURL(for videoID: String) -> URL? {
        if let audio = DownloadStore.shared.entry(videoId: videoID, kind: .audio),
           audio.status == .completed,
           FileManager.default.fileExists(atPath: audio.fileURL.path) {
            return audio.fileURL
        }
        if let video = DownloadStore.shared.entry(videoId: videoID, kind: .video),
           video.status == .completed,
           FileManager.default.fileExists(atPath: video.fileURL.path) {
            return video.fileURL
        }
        return nil
    }

    private func localTranscriptionEligibility() -> LocalTranscriptionEligibility {
        guard settingsStore.settings.autoGenerateLocalTranscripts else { return .disabled }
        guard !ProcessInfo.processInfo.isLowPowerModeEnabled else { return .lowPowerMode }
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let capacity = try? documents.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        ).volumeAvailableCapacityForImportantUsage
        guard (capacity ?? Int64.max) >= LocalTranscriptionPolicy.minimumFreeBytes else {
            return .insufficientStorage
        }
        return .allowed
    }

    /// Local playback starts first. Caption metadata then reuses the existing
    /// cache and in-flight coalescing path without becoming a playback gate.
    private func loadLocalCaptionMetadata(video: Video, generation: UInt64) {
        captionMetadataTask?.cancel()
        captionMetadataTask = Task { [weak self] in
            guard let self else { return }
            let cached = await VideoPreloadCache.shared.consume(videoId: video.id).playerInfo
            let info: PlayerInfo?
            if let cached {
                info = cached
            } else {
                let sharedFetch = await VideoPreloadCache.shared.getOrFetchPlayerInfo(
                    videoId: video.id
                )
                info = await sharedFetch.value
                if let info {
                    await VideoPreloadCache.shared.store(playerInfo: info, for: video.id)
                }
            }
            guard !Task.isCancelled,
                  self.commandGate.isCurrent(generation),
                  self.currentVideo?.id == video.id,
                  let captionIdentity = self.captionIdentity,
                  captionIdentity.itemID == video.id else { return }
            guard let info else {
                _ = self.playerState.vm.failPreparedAudioCaptionMetadata(
                    identity: captionIdentity
                )
                return
            }
            self.applyPreparedAudioCaptions(
                info.captionTracks,
                video: video,
                generation: generation
            )
        }
    }

    private func persistCurrentPosition(force: Bool, position: TimeInterval? = nil) {
        guard let video = currentVideo else { return }
        let duration = playerState.vm.duration
        let value = position ?? playerState.vm.player.currentTime().seconds
        guard duration.isFinite, duration > 0, value.isFinite, value >= 0 else { return }
        let now = Date()
        guard force || PlaybackPositionPolicy.shouldWritePeriodicCheckpoint(
            lastWrite: lastPositionCheckpointAt,
            now: now
        ) else { return }
        lastPositionCheckpointAt = now
        Task {
            await VideoStateStore.shared.save(
                videoId: video.id,
                position: value,
                duration: duration
            )
        }
    }

    private func record(
        _ diagnostic: ProgressiveAudioResourceLoader.Diagnostic,
        video: Video,
        generation: UInt64,
        loaderID: UUID
    ) {
        guard commandGate.isCurrent(generation), activeLoaderID == loaderID,
              currentVideo?.id == video.id else { return }
        if diagnostic.stage == "waiting-wifi", let video = currentVideo {
            apply(.waitingForWiFi(generation: generation))
            DownloadStore.shared.update(
                videoId: video.id,
                kind: .audio,
                status: .waitingForWiFi,
                progress: downloadProgress
            )
        } else if (diagnostic.stage.hasPrefix("retry-backoff") || diagnostic.stage.hasPrefix("validator-retry")), let video = currentVideo {
            apply(.reconnecting(generation: generation))
            DownloadStore.shared.update(
                videoId: video.id,
                kind: .audio,
                status: .reconnecting,
                progress: downloadProgress
            )
        } else if diagnostic.stage == "range-response" || diagnostic.stage == "first-response" {
            if status == .reconnecting || status == .waitingForWiFi {
                apply(.buffering(generation: generation))
            }
        }
        let status = diagnostic.statusCode.map(String.init) ?? "-"
        let offset = diagnostic.requestedOffset.map(String.init) ?? "-"
        let bytes = diagnostic.byteCount.map(String.init) ?? "-"
        let total = diagnostic.expectedBytes.map(String.init) ?? "-"
        let ranged = diagnostic.rangeSupported.map(String.init) ?? "-"
        let contentType = diagnostic.contentType ?? "-"
        let contentEncoding = diagnostic.contentEncoding ?? "-"
        let bodyClass = diagnostic.bodyClass ?? "-"
        instantAudioLog.notice(
            "[ttfa] stage=\(diagnostic.stage, privacy: .public) ms=\(diagnostic.elapsedMilliseconds) status=\(status, privacy: .public) type=\(contentType, privacy: .public) encoding=\(contentEncoding, privacy: .public) body=\(bodyClass, privacy: .public) offset=\(offset, privacy: .public) bytes=\(bytes, privacy: .public) total=\(total, privacy: .public) ranges=\(ranged, privacy: .public)"
        )
        AudioDiagnostics.shared.record(
            source: "range-loader",
            event: diagnostic.stage,
            decision: "offset=\(offset) bytes=\(bytes) total=\(total) status=\(status) type=\(contentType) encoding=\(contentEncoding) body=\(bodyClass)",
            player: playerState.vm.player,
            itemID: currentVideo?.id,
            commandGeneration: commandGate.generation
        )
    }

    @discardableResult
    private func apply(_ event: AudioFirstAuthoritativeState.Event) -> Bool {
        guard authoritativeState.reduce(event) else { return false }
        downloadProgress = authoritativeState.downloadProgress
        switch authoritativeState.phase {
        case .idle: status = .idle
        case .resolving: status = .resolving
        case .buffering: status = .buffering
        case .reconnecting: status = .reconnecting
        case .waitingForWiFi: status = .waitingForWiFi
        case .playing: status = .playing
        case .finalizing: status = .preparingAudio
        case .finalizationPending(let message): status = .finalizationPending(message)
        case .completed: status = .completed
        case .terminalFailure(let message): status = .failed(message)
        }
        return true
    }

    private var elapsedMilliseconds: Int {
        Int((ContinuousClock.now - tapStartedAt).timeInterval * 1000)
    }

    private func markTiming(_ stage: String, details: String = "") {
        instantAudioLog.notice(
            "[ttfa] stage=\(stage, privacy: .public) ms=\(self.elapsedMilliseconds) \(details, privacy: .public)"
        )
    }

    private func canStore(_ bytes: Int64) -> Bool {
        DownloadStore.shared.canStore(
            additionalBytes: bytes,
            limitBytes: Int64(max(256, settingsStore.settings.offlineStorageLimitMB)) * 1024 * 1024
        )
    }

    private func storageLimitError() -> NSError {
        NSError(
            domain: "iPocketTubeOffline",
            code: 3,
            userInfo: [NSLocalizedDescriptionKey: String(localized: "Offline collection storage limit reached. Delete items or raise the limit in Settings.", bundle: .module)]
        )
    }

    nonisolated private static func representationProfile(
        plan: OfflineAudioDownloadPlan,
        format: VideoFormat
    ) -> String {
        "\(plan.source.rawValue)|itag=\(format.itag ?? -1)|bitrate=\(format.bitrate ?? 0)|\(plan.downloadFileExtension)"
    }

    nonisolated private static func legacyRepresentationProfile(
        plan: OfflineAudioDownloadPlan,
        format: VideoFormat
    ) -> String {
        "\(plan.source.rawValue)|\(format.bitrate ?? 0)|\(plan.downloadFileExtension)"
    }

    private func atomicallyInstall(staging: URL, destination: URL) throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(
                destination,
                withItemAt: staging,
                backupItemName: nil,
                options: .usingNewMetadataOnly
            )
        } else {
            try FileManager.default.moveItem(at: staging, to: destination)
        }
    }
}

private extension Duration {
    var timeInterval: TimeInterval {
        let parts = components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}
#endif
