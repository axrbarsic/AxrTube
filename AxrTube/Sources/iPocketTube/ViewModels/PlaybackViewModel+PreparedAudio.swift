#if os(iOS)
import AVFoundation
import MediaPlayer
import iPocketTubeCore
import UIKit

extension PlaybackViewModel {
    @discardableResult
    func beginPreparedAudioCaptions(video: Video) -> CaptionPlaybackIdentity {
        captionsManager.beginPlaybackItem(
            video.id,
            bookMetadata: transcriptBookMetadata(for: video)
        )
    }

    @discardableResult
    func applyPreparedAudioCaptions(
        _ tracks: [CaptionTrack],
        identity: CaptionPlaybackIdentity
    ) -> Bool {
        captionsManager.applyAvailableCaptions(
            tracks,
            for: identity,
            preferredLanguage: settings.preferredCaptionLanguage,
            currentTime: currentTime
        )
    }

    @discardableResult
    func failPreparedAudioCaptionMetadata(
        identity: CaptionPlaybackIdentity
    ) -> Bool {
        captionsManager.failCaptionMetadata(for: identity)
    }

    @discardableResult
    func prepareLocalTranscriptFallback(
        identity: CaptionPlaybackIdentity,
        eligibility: LocalTranscriptionEligibility
    ) -> Bool {
        captionsManager.prepareLocalFallback(
            for: identity,
            eligibility: eligibility
        )
    }

    @discardableResult
    func startLocalTranscriptFallback(
        request: LocalTranscriptRequest,
        identity: CaptionPlaybackIdentity
    ) -> Bool {
        captionsManager.startLocalTranscription(
            request: request,
            for: identity,
            currentTime: currentTime
        )
    }

    /// Installs a direct audio item supplied by the progressive offline cache.
    /// This bypasses every video/HLS/IFrame/end-card/ad path while retaining the
    /// proven AVAudioSession, interruption, remote-command, and recovery graph.
    func loadPreparedAudio(
        item: AVPlayerItem,
        video: Video,
        startImmediately: Bool,
        resumePosition: TimeInterval? = nil
    ) {
        if captionsManager.activePlaybackIdentity?.itemID != video.id {
            _ = captionsManager.beginPlaybackItem(
                video.id,
                bookMetadata: transcriptBookMetadata(for: video)
            )
        }
        let previousPosition = currentTime
        let previousDuration = duration
        if settings.historyState == .enabled, previousDuration > 0 {
            let flush = tracker.transition(
                to: video.id,
                cpn: InnerTubeAPI.generateCPN(),
                flushPosition: previousPosition,
                flushDuration: previousDuration
            )
            Task { await flush() }
        } else {
            tracker.transition(
                to: video.id,
                cpn: InnerTubeAPI.generateCPN(),
                flushPosition: 0,
                flushDuration: 0
            )
        }

        loadTask?.cancel()
        exhaustiveRetryTask?.cancel()
        itemObserverTask?.cancel()
        endObserverTask?.cancel()
        stallObserverTask?.cancel()
        audioScopeInstallationTask?.cancel()
        player.pause()
        player.replaceCurrentItem(with: nil)

        currentVideo = video
        playerInfo = nil
        isAudioOnlyMode = true
        audioOnlyItemActive = true
        isLoading = true
        isPlaying = false
        videoEnded = false
        error = nil
        currentTime = 0
        duration = video.duration ?? 0
        relatedVideos = []
        endCards = []
        chapters = []
        hasNext = false
        hasPrevious = false
        audioInterruptionResumeTask?.cancel()
        remotePauseClassificationTask?.cancel()
        endInterruptionBackgroundTask()
        audioInterruptionState.reset()
        setupRateObserver()
        setupRemoteCommandCenter()
        _ = Self.activatePlaybackAudioSession(reason: "audio-first prepared item")
        updateNowPlayingInfo()

        itemObserverTask = Task { [weak self, weak item] in
            guard let item else { return }
            for await status in item.statusStream {
                guard let self, !Task.isCancelled else { return }
                switch status {
                case .readyToPlay:
                    let seconds = item.duration.seconds
                    if seconds.isFinite, seconds > 0 { self.duration = seconds }
                    let saved: TimeInterval
                    if let resumePosition, resumePosition.isFinite {
                        saved = max(0, resumePosition)
                    } else {
                        saved = await VideoStateStore.shared.restoredPosition(
                            for: video.id,
                            actualDuration: self.duration
                        )
                    }
                    guard self.player.currentItem === item else { return }
                    if saved > 5, self.duration <= 0 || saved < self.duration - 2 {
                        await self.player.seek(
                            to: CMTime(seconds: saved, preferredTimescale: 600),
                            toleranceBefore: .zero,
                            toleranceAfter: .zero
                        )
                        guard self.player.currentItem === item else { return }
                        self.currentTime = saved
                    }
                    self.isLoading = false
                    if startImmediately { self.startPreparedAudioPlayback() }
                case .failed:
                    self.isLoading = false
                    self.isPlaying = false
                    self.error = item.error
                case .unknown:
                    break
                @unknown default:
                    break
                }
            }
        }

        endObserverTask = Task { [weak self, weak item] in
            guard let item else { return }
            let notifications = NotificationCenter.default.notifications(
                named: AVPlayerItem.didPlayToEndTimeNotification,
                object: item
            )
            for await _ in notifications {
                guard let self, !Task.isCancelled else { return }
                self.handlePlaybackEnd()
            }
        }

        // Do not ask AVPlayer to predict that the entire remote item can finish
        // without a stall before it emits first audio. On a constrained link
        // that prediction can delay playback until download reaches 100%.
        // AudioFirstPlaybackCoordinator restores conservative automatic waiting
        // after the timeline has actually advanced.
        player.automaticallyWaitsToMinimizeStalling =
            ProgressivePlaybackWaitPolicy.automaticallyWaitsToMinimizeStalling(
                timelineHasAdvanced: false
            )
        player.replaceCurrentItem(with: item)
        audioScopeInstallationTask = Task { [weak self, weak item] in
            guard let self, let item else { return }
            do {
                let attachment = try await RealtimeAudioScopeCapture.makeAttachment(
                    on: item,
                    videoID: video.id
                )
                guard !Task.isCancelled, self.player.currentItem === item else { return }
                RealtimeAudioScopeRegistry.shared.activate(attachment.context)
                item.audioMix = attachment.mix
            } catch is CancellationError {
                return
            } catch {
                AudioDiagnostics.shared.record(
                    source: "audio-scope",
                    event: "pcm-tap.unavailable",
                    decision: "preparing-fallback",
                    player: self.player,
                    itemID: video.id,
                    error: error
                )
            }
        }
        UIApplication.shared.isIdleTimerDisabled = false
    }

    func startPreparedAudioPlayback() {
        guard player.currentItem != nil else { return }
        _ = Self.activatePlaybackAudioSession(reason: "audio-first initial buffer ready")
        setupRemoteCommandCenter()
        player.playImmediately(atRate: Float(settings.playbackSpeed))
        audioInterruptionState.playbackBecameActive()
        isPlaying = true
        isLoading = false
        updateNowPlayingInfo()
        updateNowPlayingPlayback()
    }
}
#endif
