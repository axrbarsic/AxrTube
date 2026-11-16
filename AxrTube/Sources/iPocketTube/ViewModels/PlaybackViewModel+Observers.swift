import AVFoundation
import os
#if canImport(UIKit)
import MediaPlayer
#endif
import iPocketTubeCore

private let playerLog = CrashlyticsLogger(category: "Player")

// MARK: - AVPlayer Observers

extension PlaybackViewModel {

    func setupTimeObserver() {
        guard timeObserver == nil else { return }
        let interval = CMTime(
            seconds: CaptionTranscriptPolicy.activeCueObserverInterval,
            preferredTimescale: 600
        )
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: nil) { [weak self] time in
            guard let self else { return }
            let seconds = time.seconds
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Don't overwrite the slider position or trigger SponsorBlock auto-seeks
                // while the user is scrubbing. Auto-seeks call seek() → showControls() →
                // scheduleControlsHide(), which cancels and restarts the 4 s hide-timer
                // every 0.5 s, preventing controls from ever auto-hiding post-scrub.
                guard !self.isScrubbing else { return }
                guard !self.sponsorBlockManager.isSkippingSegment else { return }
                // Suspend time updates during a quality-change transition: the new
                // AVPlayerItem is not yet ready and player.currentTime() may return 0
                // or a stale value. currentTime is restored by qualityItemDidBecomeReady.
                guard !self.isQualityChangePending else { return }
                self.applyObservedPlaybackTime(seconds)
                self.checkSponsorSkip(at: seconds)
                self.updateCaptionCue(for: seconds)
                if self.statsForNerdsVisible { self.updateStatsSnapshot() }
            }
        }
    }

    /// Synchronizes UI and Now Playing from the actual long-lived AVPlayer item.
    /// This is safe to call repeatedly on foreground and Downloads appearance and
    /// never installs a second periodic observer.
    func synchronizePlaybackTimeFromPlayer(reason: String) {
        guard player.currentItem != nil, !isScrubbing, !isQualityChangePending else { return }
        let observed = player.currentTime().seconds
        applyObservedPlaybackTime(observed)
        #if canImport(UIKit)
        updateNowPlayingPlayback()
        AudioDiagnostics.shared.record(
            event: "timeline.lifecycleSync",
            decision: reason,
            player: player,
            recoveryGeneration: audioInterruptionGeneration,
            itemID: currentVideo?.id,
            commandGeneration: nowPlayingSourceState.generation
        )
        #endif
    }

    private func applyObservedPlaybackTime(_ observed: TimeInterval) {
        currentTime = PlaybackPositionPolicy.reconciledObservedPosition(
            observed: observed,
            current: currentTime
        )
    }

    func setupRateObserver() {
        // KVO on player.rate so isPlaying stays in sync when the system externally
        // pauses the player (e.g. headphones removed, audio session interruption ends
        // without shouldResume). Without this, isPlaying stays true while the player
        // is actually silent, causing handleForeground() to re-start a ghost session.
        rateObserver = player.observe(\.rate, options: [.new]) { [weak self] _, change in
            guard let self, let newRate = change.newValue else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.player.rate > 0, self.enforcePlaybackAuthority() {
                    #if canImport(UIKit)
                    AudioDiagnostics.shared.record(event: "rate.unauthorized.blocked",
                        decision: "interruptionOrUserPauseWins", player: self.player,
                        recoveryGeneration: self.audioInterruptionGeneration)
                    #endif
                    return
                }
                #if os(iOS)
                if LocalDubbingAudioOwnershipPolicy.shouldSuppressSourceRate(
                    localPlaybackIsActive: self.localDubbingManager.isPlaying,
                    sourceRate: newRate
                ) {
                    self.player.pause()
                    self.isPlaying = false
                    return
                }
                #endif
                // Ignore rate changes that we ourselves triggered (load/pause/resume/stop)
                // by only acting when the player goes silent unexpectedly while we
                // believed it was playing.
                //
                // Also ignore rate→0 when currentTime is within 1 s of the total
                // duration: that's the video naturally reaching its end, not a stall.
                // In that case AVFoundation will post didPlayToEndTimeNotification
                // immediately after, which calls handlePlaybackEnd() correctly.
                // Without this guard the recovery logic seeks back by ~1 s and fights
                // the natural ending, causing repeated spurious stall reports and
                // blocking the end-of-video / autoplay-next flow (crash log confirmed
                // via Crashlytics: stall #1–4 at t=15s for a 15.3 s video).
                let nearEnd = self.duration > 0 && self.currentTime >= self.duration - 1.0
                let playerWentSilent = newRate == 0 && self.isPlaying && !self.isSwappingItem && !self.isHandlingAudioInterruption && !nearEnd
                if playerWentSilent {
                    // AVPlayer is allowed to publish rate=0 before iOS delivers the
                    // matching interruption notification. Classifying synchronously
                    // erased the original play intent and scheduled a stall retry that
                    // later fought the microphone session. Give the notification one
                    // short main-run-loop window; a began/reset/route event increments
                    // generation and cancels this classification causally.
                    let classificationGeneration = self.audioInterruptionGeneration
                    #if canImport(UIKit)
                    AudioDiagnostics.shared.record(
                        event: "rate.zero.pendingClassification",
                        decision: "waitForSystemAudioEvent",
                        player: self.player,
                        recoveryGeneration: classificationGeneration
                    )
                    #endif
                    try? await Task.sleep(for: .milliseconds(150))
                    guard self.audioInterruptionGeneration == classificationGeneration,
                          self.isPlaying,
                          self.player.rate == 0,
                          !self.isSwappingItem,
                          !self.isHandlingAudioInterruption else {
                        #if canImport(UIKit)
                        AudioDiagnostics.shared.record(
                            event: "rate.zero.classificationCancelled",
                            decision: "systemAudioEventWon",
                            player: self.player,
                            recoveryGeneration: self.audioInterruptionGeneration
                        )
                        #endif
                        return
                    }
                    if !PlaybackLifecyclePolicy.shouldRunStallRecovery(
                        scene: self.playbackSceneState,
                        hasTrueAudioInterruption: self.isHandlingAudioInterruption,
                        isReplacingItem: self.isSwappingItem
                    ) {
                        // Side-button lock is a scene transition, not proof that the
                        // AVPlayerItem or output graph is corrupt. Keep the same item,
                        // session and play intent; only reassert the rate if iOS briefly
                        // published zero without an interruption. Never seek/rebuild.
                        #if canImport(UIKit)
                        AudioDiagnostics.shared.record(
                            event: "rate.zero.sceneTransition",
                            decision: "preserveItemSessionNowPlaying",
                            player: self.player,
                            recoveryGeneration: classificationGeneration,
                            itemID: self.currentVideo?.id
                        )
                        #endif
                        self.requestPlaybackStart(reason: "scene or buffer recovery")
                        #if canImport(UIKit)
                        self.updateNowPlayingInfo()
                        self.updateNowPlayingPlayback()
                        #endif
                        return
                    }
                    if self.audioOnlyItemActive {
                        // Progressive audio owns its range loader and retry policy.
                        // Escalating into the legacy video/HLS extractor here creates
                        // a second source owner and can replace a still-valid sparse
                        // item after a temporary range wait.
                        #if canImport(UIKit)
                        AudioDiagnostics.shared.record(
                            event: "rate.zero.progressiveAudio",
                            decision: "rangeLoaderOwnsRecovery",
                            player: self.player,
                            recoveryGeneration: classificationGeneration,
                            itemID: self.currentVideo?.id
                        )
                        #endif
                        self.requestPlaybackStart(reason: "scene or buffer recovery")
                        return
                    }
                    self.isPlaying = false
                    #if canImport(UIKit)
                    AudioDiagnostics.shared.record(
                        event: "rate.zero.confirmedStall",
                        decision: "stallRecovery",
                        player: self.player,
                        recoveryGeneration: classificationGeneration
                    )
                    #endif
                    playerLog.notice("[rateObserver] player.rate→0 while isPlaying=true — syncing isPlaying=false")
                    self.stallCount += 1
                    if self.firstRapidStallTime == nil { self.firstRapidStallTime = Date() }
                    let t = Int(self.currentTime)
                    let stallError = NSError(
                        domain: "iPocketTube.PlaybackStall",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "player.rate→0 while isPlaying=true at t=\(t)s (stall #\(self.stallCount))"]
                    )
                    playerLog.recordNonFatal(stallError, userInfo: [
                        "video_id":       self.currentVideo?.id ?? "unknown",
                        "stall_at_time":  String(t),
                        "stall_count":    String(self.stallCount),
                        "video_duration": String(Int(self.duration)),
                        "stall_trigger":  "rateObserver"
                    ])
                    #if canImport(UIKit)
                    self.updateNowPlayingPlayback()
                    #endif
                    // Weak-network aware recovery: no seek or reload while offline
                    // or while bytes still arrive, so the buffer survives drop-outs.
                    if let item = self.player.currentItem {
                        self.beginStallRecovery(item: item, source: "rateObserver")
                    }
                }
            }
        }
    }

    #if canImport(UIKit)
    func setupAirPlayObserver() {
        airPlayObserver = player.observe(\.isExternalPlaybackActive, options: [.new]) { [weak self] _, change in
            guard let self, let active = change.newValue else { return }
            Task { @MainActor [weak self] in
                self?.isAirPlaying = active
            }
        }
    }
    #endif
}
