import AVFoundation
import os
#if canImport(UIKit)
import UIKit
import MediaPlayer
#endif
import iPocketTubeCore

private let playerLog = CrashlyticsLogger(category: "Player")

// File-scope factory — deliberately nonisolated so MPMediaItemArtwork can invoke the
// returned closure from MediaPlayer's internal serial queue without triggering the
// Swift 6 actor-isolation assertion (_swift_task_checkIsolatedSwift → EXC_BREAKPOINT).
// An inline closure defined inside a @MainActor method inherits @MainActor isolation
// even when it only captures a value-type snapshot; extracting it here breaks that.
#if canImport(UIKit)
private func makeNonisolatedArtworkProvider(image: UIImage) -> (CGSize) -> UIImage {
    { _ in image }
}
#endif

// MARK: - Now Playing (lock screen + Dynamic Island)

#if canImport(UIKit)
extension PlaybackViewModel {

    /// Restores the category and mode that media-services reset or another app may
    /// have cleared, without taking ownership of the route.
    @discardableResult
    nonisolated static func configurePlaybackAudioSession(reason: String) -> Bool {
        let session = AVAudioSession.sharedInstance()
        AudioDiagnostics.shared.record(
            event: "session.configure.request",
            decision: reason
        )
        do {
            // Ask iOS to interrupt this continuous-content session for short spoken
            // prompts (for example AirPods announcements) instead of ducking it.
            try session.setCategory(.playback, mode: .spokenAudio)
            AudioDiagnostics.shared.record(
                event: "session.configure.success",
                decision: reason
            )
            playerLog.notice("[audioSession] configured for \(reason)")
            return true
        } catch {
            AudioDiagnostics.shared.record(
                event: "session.configure.failure",
                decision: reason,
                error: error
            )
            playerLog.error("[audioSession] configuration failed for \(reason): \(error.localizedDescription)")
            return false
        }
    }

    /// Reasserts the complete playback-session contract before any remote resume.
    /// iOS may leave the session inactive after a device-lock transition even though
    /// AVPlayer still accepts a new rate; that produces a moving timeline with no
    /// audible route. This method is nonisolated so the MediaPlayer command callback
    /// can finish activation before it reports `.success` to the Lock Screen.
    @discardableResult
    nonisolated static func activatePlaybackAudioSession(reason: String) -> Bool {
        let session = AVAudioSession.sharedInstance()
        guard configurePlaybackAudioSession(reason: reason) else { return false }
        AudioDiagnostics.shared.record(
            event: "session.activate.request",
            decision: reason
        )
        do {
            try session.setActive(true)
            AudioDiagnostics.shared.record(
                event: "session.activate.success",
                decision: reason
            )
            playerLog.notice("[audioSession] active for \(reason)")
            return true
        } catch {
            AudioDiagnostics.shared.record(
                event: "session.activate.failure",
                decision: reason,
                error: error
            )
            playerLog.error("[audioSession] activation failed for \(reason): \(error.localizedDescription)")
            return false
        }
    }

    /// Stops owning the route so microphone/call sessions can start without iPocketTube
    /// repeatedly reacquiring audio in the background.
    @discardableResult
    nonisolated static func deactivatePlaybackAudioSession(reason: String) -> Bool {
        AudioDiagnostics.shared.record(
            event: "session.deactivate.request",
            decision: reason
        )
        do {
            try AVAudioSession.sharedInstance().setActive(
                false,
                options: .notifyOthersOnDeactivation
            )
            AudioDiagnostics.shared.record(
                event: "session.deactivate.success",
                decision: reason
            )
            playerLog.notice("[audioSession] yielded route for \(reason)")
            return true
        } catch {
            AudioDiagnostics.shared.record(
                event: "session.deactivate.failure",
                decision: reason,
                error: error
            )
            playerLog.error("[audioSession] deactivation failed for \(reason): \(error.localizedDescription)")
            return false
        }
    }

    @discardableResult
    func resumeAudiblePlayback(
        reason: String,
        countAutomaticResume: Bool = false
    ) -> Bool {
        guard player.currentItem != nil,
              !isHandlingAudioInterruption,
              !audioInterruptionState.mediaServicesAreLost else {
            AudioDiagnostics.shared.record(
                event: "recovery.resume.rejected",
                decision: reason,
                player: player,
                recoveryGeneration: audioInterruptionGeneration
            )
            return false
        }
        if videoEnded {
            videoEnded = false
            seek(to: 0)
        }
        player.playImmediately(atRate: Float(settings.playbackSpeed))
        isPlaying = true
        if countAutomaticResume { audioInterruptionResumeCount &+= 1 }
        updateNowPlayingPlayback()
        AudioDiagnostics.shared.record(
            event: "recovery.resume.commanded",
            decision: reason,
            player: player,
            recoveryGeneration: audioInterruptionGeneration
        )
        scheduleAudioRecoveryVerification(reason: reason)
        return true
    }

    /// Detaches and reattaches the current item after an interruption so AVPlayer
    /// creates a fresh presentation/audio renderer. A media-services reset uses a
    /// new AVPlayerItem backed by the same asset, per Apple's reinitialisation rule.
    @discardableResult
    private func rebuildPlaybackGraph(
        reason: String,
        useFreshItem: Bool,
        resumeAfterRebuild: Bool,
        countAutomaticResume: Bool = false
    ) -> Bool {
        guard let oldItem = player.currentItem else {
            AudioDiagnostics.shared.record(
                event: "recovery.graph.missingItem",
                decision: reason,
                player: player,
                recoveryGeneration: audioInterruptionGeneration
            )
            return false
        }

        let token = audioInterruptionGeneration
        let position = max(0, currentTime)
        let replacement: AVPlayerItem
        if useFreshItem {
            replacement = AVPlayerItem(asset: oldItem.asset)
            replacement.preferredForwardBufferDuration = oldItem.preferredForwardBufferDuration
            replacement.canUseNetworkResourcesForLiveStreamingWhilePaused =
                oldItem.canUseNetworkResourcesForLiveStreamingWhilePaused
            replacement.audioMix = oldItem.audioMix
            replacement.videoComposition = oldItem.videoComposition
        } else {
            replacement = oldItem
        }

        audioRecoveryVerificationTask?.cancel()
        player.pause()
        isPlaying = false
        isSwappingItem = true
        player.replaceCurrentItem(with: nil)
        player.replaceCurrentItem(with: replacement)
        AudioDiagnostics.shared.record(
            event: "recovery.graph.rebuilt",
            decision: reason,
            player: player,
            recoveryGeneration: token
        )

        let finish: @Sendable () -> Void = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isSwappingItem = false
                guard self.audioInterruptionGeneration == token else {
                    AudioDiagnostics.shared.record(
                        event: "recovery.graph.staleCompletion",
                        decision: "ignored",
                        player: self.player,
                        recoveryGeneration: token,
                        itemID: self.currentVideo?.id
                    )
                    return
                }
                guard !self.audioInterruptionState.mediaServicesAreLost,
                      (!resumeAfterRebuild || !self.isHandlingAudioInterruption) else {
                    self.player.pause()
                    self.isPlaying = false
                    self.updateNowPlayingPlayback()
                    AudioDiagnostics.shared.record(
                        event: "recovery.graph.completionDiscarded",
                        decision: reason,
                        player: self.player,
                        recoveryGeneration: token
                    )
                    return
                }
                if resumeAfterRebuild {
                    _ = self.resumeAudiblePlayback(
                        reason: reason,
                        countAutomaticResume: countAutomaticResume
                    )
                } else {
                    self.player.pause()
                    self.isPlaying = false
                    self.updateNowPlayingPlayback()
                    AudioDiagnostics.shared.record(
                        event: "recovery.graph.readyPaused",
                        decision: reason,
                        player: self.player,
                        recoveryGeneration: token
                    )
                }
            }
        }

        if position > 0 {
            player.seek(
                to: CMTime(seconds: position, preferredTimescale: 600),
                toleranceBefore: .zero,
                toleranceAfter: .zero
            ) { _ in finish() }
        } else {
            finish()
        }
        return true
    }

    private func scheduleAudioRecoveryVerification(reason: String) {
        audioRecoveryVerificationTask?.cancel()
        let token = audioInterruptionGeneration
        audioRecoveryVerificationTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard let self, !Task.isCancelled,
                  self.audioInterruptionGeneration == token,
                  self.isPlaying,
                  !self.isHandlingAudioInterruption else { return }

            let routeIsAvailable = !AVAudioSession.sharedInstance().currentRoute.outputs.isEmpty
            let playerIsAdvancing = self.player.rate > 0
                && self.player.timeControlStatus != .paused
                && self.player.status != .failed
                && self.player.currentItem?.status != .failed
            guard routeIsAvailable && playerIsAdvancing else {
                self.player.pause()
                self.isPlaying = false
                self.updateNowPlayingPlayback()
                if routeIsAvailable,
                   self.player.currentItem != nil,
                   self.lastAudioGraphRepairGeneration != token {
                    self.lastAudioGraphRepairGeneration = token
                    AudioDiagnostics.shared.record(
                        event: "recovery.verify.repairGraph",
                        decision: reason,
                        player: self.player,
                        recoveryGeneration: token,
                        itemID: self.currentVideo?.id
                    )
                    _ = self.rebuildPlaybackGraph(
                        reason: "\(reason) graph repair",
                        useFreshItem: true,
                        resumeAfterRebuild: true
                    )
                    return
                }
                self.audioInterruptionState.invalidatePendingRecovery()
                AudioDiagnostics.shared.record(
                    event: "recovery.verify.failed",
                    decision: "stayPaused",
                    player: self.player,
                    recoveryGeneration: token
                )
                return
            }
            AudioDiagnostics.shared.record(
                event: "recovery.verify.transportHealthy",
                decision: reason,
                player: self.player,
                recoveryGeneration: token
            )
        }
    }

    func performUserPause(reason: String) {
        checkpointPlaybackPosition()
        audioRecoveryVerificationTask?.cancel()
        audioInterruptionState.userPaused()
        player.pause()
        isPlaying = false
        updateNowPlayingPlayback()
        AudioDiagnostics.shared.record(
            event: "user.pause",
            decision: reason,
            player: player,
            recoveryGeneration: audioInterruptionGeneration
        )
    }

    func performUserPlay(reason: String) {
        guard player.currentItem != nil,
              nowPlayingSourceState.itemKey != nil,
              !audioInterruptionState.mediaServicesAreLost else {
            player.pause()
            isPlaying = false
            updateNowPlayingPlayback()
            AudioDiagnostics.shared.record(
                event: "user.play.rejected",
                decision: "\(reason) missingItemOrMediaServicesLost",
                player: player,
                recoveryGeneration: audioInterruptionGeneration,
                itemID: currentVideo?.id
            )
            return
        }
        let wasRecoveringMissingEnded = isHandlingAudioInterruption
        let action = audioInterruptionState.userRequestedPlay()
        if wasRecoveringMissingEnded {
            AudioDiagnostics.shared.record(
                event: "interruption.manualRecovery",
                decision: "\(reason) \(action)",
                player: player,
                recoveryGeneration: audioInterruptionGeneration,
                itemID: currentVideo?.id
            )
        }
        guard Self.activatePlaybackAudioSession(reason: reason) else {
            player.pause()
            isPlaying = false
            updateNowPlayingPlayback()
            return
        }
        _ = resumeAudiblePlayback(reason: reason)
    }

    func handleAudioInterruption(
        type: AVAudioSession.InterruptionType,
        options: AVAudioSession.InterruptionOptions = [],
        reason: UInt? = nil,
        wasSuspended: Bool = false,
        source: AudioInterruptionStateMachine.Source = .systemInterruption
    ) {
        AudioDiagnostics.shared.record(
            event: "interruption.notification",
            decision: "\(source) \(type == .began ? "began" : "ended")",
            player: player,
            interruptionType: type.rawValue,
            interruptionOptions: options.rawValue,
            interruptionReason: reason,
            interruptionWasSuspended: wasSuspended,
            recoveryGeneration: audioInterruptionGeneration
        )
        switch type {
        case .began:
            // Duplicate began notifications are possible while voice input negotiates
            // its route. Never overwrite the original was-playing snapshot with the
            // paused state from a later duplicate.
            let action = audioInterruptionState.sourceBegan(
                source,
                wasPlaying: isPlaying || player.rate > 0
            )
            guard action == .pauseAndYield else {
                playerLog.notice("[interruption] duplicate began ignored")
                return
            }
            checkpointPlaybackPosition()
            // A previously scheduled stall retry must never restart playback while
            // the microphone owns the route.
            exhaustiveRetryTask?.cancel()
            exhaustiveRetryTask = nil
            player.pause()
            isPlaying = false
            updateNowPlayingPlayback()
            // The system has already made the session inactive. Apple explicitly
            // recommends updating playback state here, not competing with another
            // setActive transition while the microphone/prompt owns the route.
            playerLog.notice("[interruption] began — player paused and route yielded; wasPlaying=\(self.wasPlayingBeforeInterruption)")

        case .ended:
            let action = audioInterruptionState.sourceEnded(
                source,
                shouldResume: options.contains(.shouldResume)
            )
            guard action != .ignore else {
                playerLog.notice("[interruption] ended without active interruption — ignored")
                return
            }
            let shouldResume = action == .rebuildGraphAndResume
            playerLog.notice("[interruption] ended — shouldResume=\(shouldResume)")

            if shouldResume,
               Self.activatePlaybackAudioSession(reason: "interruption ended") {
                // Preserve the current saved-file item and exact position first.
                // A fresh graph is created only if the post-resume health check
                // proves that the renderer did not recover.
                if !resumeAudiblePlayback(
                    reason: "interruption ended",
                    countAutomaticResume: true
                ) {
                    player.pause()
                    isPlaying = false
                    updateNowPlayingPlayback()
                }
            } else {
                // Keep AVPlayer and the public state honestly paused. A later remote
                // Play will activate the session synchronously before changing rate.
                player.pause()
                isPlaying = false
                updateNowPlayingPlayback()
            }

        @unknown default:
            break
        }
    }

    private func checkpointPlaybackPosition() {
        guard let video = currentVideo else { return }
        let position = player.currentTime().seconds
        let currentDuration = duration
        guard position.isFinite, currentDuration.isFinite, currentDuration > 0 else { return }
        Task {
            await VideoStateStore.shared.save(
                videoId: video.id,
                position: position,
                duration: currentDuration
            )
        }
    }

    func handleAudioRouteChange(reason: AVAudioSession.RouteChangeReason) {
        checkpointPlaybackPosition()
        AudioDiagnostics.shared.record(
            event: "route.change",
            decision: String(reason.rawValue),
            player: player,
            recoveryGeneration: audioInterruptionGeneration
        )
        if reason == .newDeviceAvailable || reason == .wakeFromSleep
            || reason == .routeConfigurationChange {
            _ = audioInterruptionState.routeBecameAvailable()
            setupRemoteCommandCenter()
            if player.currentItem != nil { updateNowPlayingInfo() }
            AudioDiagnostics.shared.record(
                event: "route.ownerReasserted",
                decision: String(reason.rawValue),
                player: player,
                recoveryGeneration: audioInterruptionGeneration,
                itemID: currentVideo?.id,
                commandGeneration: nowPlayingSourceState.generation
            )
            return
        }
        guard (reason == .oldDeviceUnavailable || reason == .noSuitableRouteForCategory),
              !isHandlingAudioInterruption else { return }
        _ = audioInterruptionState.routeBecameUnavailable()
        audioRecoveryVerificationTask?.cancel()
        player.pause()
        isPlaying = false
        updateNowPlayingPlayback()
        // Keep the session active on an unplug route change; this is Apple's media
        // playback guidance and avoids a redundant activation race on the new route.
        playerLog.notice("[audioSession] old output route unavailable — staying paused")
    }

    func handleMediaServicesLost() {
        checkpointPlaybackPosition()
        _ = audioInterruptionState.mediaServicesLost(
            wasPlaying: isPlaying || player.rate > 0
        )
        audioRecoveryVerificationTask?.cancel()
        player.pause()
        isPlaying = false
        updateNowPlayingPlayback()
        AudioDiagnostics.shared.record(
            event: "mediaServices.lost",
            decision: "pause",
            player: player,
            recoveryGeneration: audioInterruptionGeneration
        )
        playerLog.notice("[audioSession] media services lost — paused; wasPlaying=\(self.wasPlayingBeforeMediaServicesLoss)")
    }

    func handleMediaServicesReset() {
        let action = audioInterruptionState.mediaServicesReset()
        audioRecoveryVerificationTask?.cancel()
        player.pause()
        isPlaying = false
        updateNowPlayingPlayback()
        _ = Self.configurePlaybackAudioSession(reason: "media services reset")
        AudioDiagnostics.shared.record(
            event: "mediaServices.reset",
            decision: action == .rebuildGraphAndStayPaused ? "rebuildStayPaused" : "stayPaused",
            player: player,
            recoveryGeneration: audioInterruptionGeneration
        )
        if action == .rebuildGraphAndStayPaused {
            _ = rebuildPlaybackGraph(
                reason: "media services reset",
                useFreshItem: true,
                resumeAfterRebuild: false
            )
        }
    }

    func setupAudioSessionObserver() {
        if audioSessionObserver != nil,
           audioRouteChangeObserver != nil,
           mediaServicesLostObserver != nil,
           mediaServicesResetObserver != nil,
           secondaryAudioHintObserver != nil {
            return
        }
        if let observer = audioSessionObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = audioRouteChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = mediaServicesLostObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = mediaServicesResetObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = secondaryAudioHintObserver {
            NotificationCenter.default.removeObserver(observer)
        }

        audioSessionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            guard let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
            let optionsValue = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            let reasonValue = notification.userInfo?[AVAudioSessionInterruptionReasonKey] as? UInt
            let wasSuspended = (notification.userInfo?[AVAudioSessionInterruptionWasSuspendedKey] as? NSNumber)?.boolValue ?? false
            Task { @MainActor [weak self] in
                self?.handleAudioInterruption(
                    type: type,
                    options: options,
                    reason: reasonValue,
                    wasSuspended: wasSuspended
                )
            }
        }

        audioRouteChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            guard let reasonValue = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else { return }
            Task { @MainActor [weak self] in
                self?.handleAudioRouteChange(reason: reason)
            }
        }

        mediaServicesLostObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.mediaServicesWereLostNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleMediaServicesLost()
            }
        }

        mediaServicesResetObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleMediaServicesReset()
            }
        }

        secondaryAudioHintObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.silenceSecondaryAudioHintNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            guard let raw = notification.userInfo?[AVAudioSessionSilenceSecondaryAudioHintTypeKey] as? UInt,
                  let type = AVAudioSession.SilenceSecondaryAudioHintType(rawValue: raw) else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch type {
                case .begin:
                    self.handleAudioInterruption(
                        type: .began,
                        options: [],
                        reason: nil,
                        wasSuspended: false,
                        source: .secondaryAudioHint
                    )
                case .end:
                    self.handleAudioInterruption(
                        type: .ended,
                        options: [.shouldResume],
                        reason: nil,
                        wasSuspended: false,
                        source: .secondaryAudioHint
                    )
                @unknown default:
                    break
                }
            }
        }
    }

    func setupRemoteCommandCenter() {
        // The app-lifetime PlaybackViewModel owns remote commands. Repeated loads,
        // ordinary pause, scene background and device lock must not tear down the
        // process-wide MediaPlayer handlers.
        setupAudioSessionObserver()
        let center = MPRemoteCommandCenter.shared()
        guard remotePlayTarget == nil else {
            AudioDiagnostics.shared.record(
                event: "remote.handlers.preserved",
                decision: "already installed",
                player: player,
                recoveryGeneration: audioInterruptionGeneration,
                itemID: currentVideo?.id,
                commandGeneration: nowPlayingSourceState.generation
            )
            return
        }

        remotePlayTarget = center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                AudioDiagnostics.shared.record(
                    event: "remote.play",
                    decision: "received",
                    player: self.player,
                    recoveryGeneration: self.audioInterruptionGeneration,
                    itemID: self.currentVideo?.id,
                    commandGeneration: self.nowPlayingSourceState.generation
                )
                self.performUserPlay(reason: "Lock Screen Play")
            }
            return .success
        }
        remotePauseTarget = center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                AudioDiagnostics.shared.record(
                    event: "remote.pause",
                    decision: "received",
                    player: self.player,
                    recoveryGeneration: self.audioInterruptionGeneration,
                    itemID: self.currentVideo?.id,
                    commandGeneration: self.nowPlayingSourceState.generation
                )
                self.performUserPause(reason: "Lock Screen Pause")
            }
            return .success
        }
        remoteToggleTarget = center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                AudioDiagnostics.shared.record(
                    event: "remote.toggle",
                    decision: self.isPlaying ? "pause" : "play",
                    player: self.player,
                    recoveryGeneration: self.audioInterruptionGeneration,
                    itemID: self.currentVideo?.id,
                    commandGeneration: self.nowPlayingSourceState.generation
                )
                if self.isPlaying {
                    self.performUserPause(reason: "Lock Screen Toggle Pause")
                } else {
                    self.performUserPlay(reason: "Lock Screen Toggle Play")
                }
            }
            return .success
        }
        center.skipForwardCommand.preferredIntervals = [10]
        remoteSkipForwardTarget = center.skipForwardCommand.addTarget { [weak self] event in
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? 10
            Task { @MainActor [weak self] in self?.seekRelative(seconds: interval) }
            return .success
        }
        center.skipBackwardCommand.preferredIntervals = [10]
        remoteSkipBackwardTarget = center.skipBackwardCommand.addTarget { [weak self] event in
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? 10
            Task { @MainActor [weak self] in self?.seekRelative(seconds: -interval) }
            return .success
        }
        remotePositionTarget = center.changePlaybackPositionCommand.addTarget { [weak self] event in
            let position = (event as? MPChangePlaybackPositionCommandEvent)?.positionTime ?? 0
            Task { @MainActor [weak self] in self?.seek(to: position) }
            return .success
        }
        remoteNextTarget = center.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in self?.playNext() }
            return .success
        }
        remotePreviousTarget = center.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in self?.playPrevious() }
            return .success
        }
        AudioDiagnostics.shared.record(
            event: "remote.handlers.installed",
            decision: "app lifetime owner",
            player: player,
            recoveryGeneration: audioInterruptionGeneration,
            itemID: currentVideo?.id,
            commandGeneration: nowPlayingSourceState.generation
        )
    }

    func updateNowPlayingInfo() {
        let video = playerInfo?.video ?? currentVideo
        guard let video else {
            clearNowPlayingInfo()
            return
        }
        let sourceGeneration = nowPlayingSourceState.activate(itemKey: video.id)
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: video.title,
            MPMediaItemPropertyArtist: video.channelTitle,
            MPNowPlayingInfoPropertyMediaType: NSNumber(
                value: (audioOnlyItemActive || video.localMediaKind == .audio
                    ? MPNowPlayingInfoMediaType.audio
                    : MPNowPlayingInfoMediaType.video).rawValue
            ),
            MPNowPlayingInfoPropertyIsLiveStream: NSNumber(value: video.isLive),
            MPNowPlayingInfoPropertyElapsedPlaybackTime: NSNumber(value: currentTime),
            MPNowPlayingInfoPropertyPlaybackRate: NSNumber(value: isPlaying ? Double(player.rate) : 0.0),
        ]
        if duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = NSNumber(value: duration)
        }
        nowPlayingInfoCache = info

        // Artwork — capture the current image by value so the MPMediaItemArtwork closure
        // never captures self. MediaPlayer calls the closure on its private serial queue;
        // capturing self (a @MainActor-isolated type) causes Swift 6 to assert actor
        // isolation via dispatch_assert_queue and throw EXC_BREAKPOINT (fix238).
        if let thumbURL = video.thumbnailURL {
            let snapshot: UIImage = cachedArtwork ?? UIImage()
            let artwork = MPMediaItemArtwork(boundsSize: CGSize(width: 600, height: 600),
                                             requestHandler: makeNonisolatedArtworkProvider(image: snapshot))
            nowPlayingInfoCache[MPMediaItemPropertyArtwork] = artwork

            // Kick off fetch only when the video changes to avoid redundant network hits.
            if cachedArtworkVideoID != video.id {
                cachedArtworkVideoID = video.id
                cachedArtwork = nil
                Task { [weak self, url = thumbURL, videoID = video.id, sourceGeneration] in
                    guard let (data, _) = try? await URLSession.shared.data(from: url),
                          let image = UIImage(data: data) else { return }
                    await MainActor.run { [weak self] in
                        guard let self,
                              self.cachedArtworkVideoID == videoID,
                              self.nowPlayingSourceState.accepts(
                                generation: sourceGeneration,
                                itemKey: videoID
                              ) else {
                            AudioDiagnostics.shared.record(
                                event: "nowPlaying.artwork.stale",
                                decision: "discarded",
                                player: self?.player,
                                itemID: videoID,
                                commandGeneration: sourceGeneration
                            )
                            return
                        }
                        self.cachedArtwork = image
                        // Update the artwork key in the cache with the real image. Use the
                        // nonisolated factory so MediaPlayer can call the closure from its
                        // internal background queue without hitting the Swift 6 actor-isolation
                        // assertion (same fix as the initial artwork registration above).
                        self.nowPlayingInfoCache[MPMediaItemPropertyArtwork] =
                            MPMediaItemArtwork(boundsSize: image.size,
                                               requestHandler: makeNonisolatedArtworkProvider(image: image))
                        self.setNowPlayingInfo(self.nowPlayingInfoCache)
                    }
                }
            }
        }

        // Update next/previous button enabled state.
        let center = MPRemoteCommandCenter.shared()
        center.nextTrackCommand.isEnabled = hasNext
        center.previousTrackCommand.isEnabled = hasPrevious

        setNowPlayingInfo(nowPlayingInfoCache)
    }

    func updateNowPlayingPlayback() {
        guard !nowPlayingInfoCache.isEmpty else {
            // Never publish a title-less dictionary: iOS renders it as the ghost
            // Lock Screen card "No Audio". Rehydrate metadata when an item still
            // exists; explicit stop remains the only path that writes nil.
            if currentVideo != nil, player.currentItem != nil {
                updateNowPlayingInfo()
            }
            return
        }
        nowPlayingInfoCache[MPNowPlayingInfoPropertyElapsedPlaybackTime] = NSNumber(value: currentTime)
        nowPlayingInfoCache[MPNowPlayingInfoPropertyPlaybackRate] = NSNumber(value: isPlaying ? Double(player.rate) : 0.0)
        setNowPlayingInfo(nowPlayingInfoCache)
    }

    func clearNowPlayingInfo(expectedGeneration: UInt64? = nil) {
        let generation = expectedGeneration ?? nowPlayingSourceState.generation
        guard nowPlayingSourceState.clear(generation: generation) else {
            AudioDiagnostics.shared.record(
                event: "nowPlaying.clear.stale",
                decision: "discarded",
                player: player,
                recoveryGeneration: audioInterruptionGeneration,
                itemID: currentVideo?.id,
                commandGeneration: generation
            )
            return
        }
        cachedArtwork = nil
        cachedArtworkVideoID = nil
        nowPlayingInfoCache = [:]
        setNowPlayingInfo(nil)
    }

    /// Writes to `MPNowPlayingInfoCenter` directly on `@MainActor` (= main thread).
    /// Do NOT use DispatchQueue.main.async here — dispatching async from @MainActor
    /// creates a new GCD block that may lack the proper queue-specific context that
    /// MediaPlayer's internal accessQueue asserts, causing EXC_BREAKPOINT.
    /// Since every caller is already @MainActor-isolated this call is always
    /// synchronous on the main thread.
    private func setNowPlayingInfo(_ info: [String: Any]?) {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        AudioDiagnostics.shared.record(
            event: info == nil ? "nowPlaying.clear" : "nowPlaying.publish",
            decision: info == nil ? "explicit stop" : (isPlaying ? "playing" : "paused recoverable"),
            player: player,
            recoveryGeneration: audioInterruptionGeneration,
            itemID: currentVideo?.id,
            commandGeneration: nowPlayingSourceState.generation
        )
    }
}
#endif
