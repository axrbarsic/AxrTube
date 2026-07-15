import AVFoundation
import os
#if canImport(UIKit)
import UIKit
import MediaPlayer
#endif
import SmartTubeIOSCore

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
        do {
            // Ask iOS to interrupt this continuous-content session for short spoken
            // prompts (for example AirPods announcements) instead of ducking it.
            try session.setCategory(.playback, mode: .spokenAudio)
            playerLog.notice("[audioSession] configured for \(reason)")
            return true
        } catch {
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
        do {
            try session.setActive(true)
            playerLog.notice("[audioSession] active for \(reason)")
            return true
        } catch {
            playerLog.error("[audioSession] activation failed for \(reason): \(error.localizedDescription)")
            return false
        }
    }

    /// Stops owning the route so microphone/call sessions can start without SmartTube
    /// repeatedly reacquiring audio in the background.
    @discardableResult
    nonisolated static func deactivatePlaybackAudioSession(reason: String) -> Bool {
        do {
            try AVAudioSession.sharedInstance().setActive(
                false,
                options: .notifyOthersOnDeactivation
            )
            playerLog.notice("[audioSession] yielded route for \(reason)")
            return true
        } catch {
            playerLog.error("[audioSession] deactivation failed for \(reason): \(error.localizedDescription)")
            return false
        }
    }

    @discardableResult
    private func resumeAudiblePlayback(reason: String) -> Bool {
        guard player.currentItem != nil else {
            playerLog.error("[audioSession] resume ignored for \(reason): AVPlayer has no current item")
            return false
        }
        if videoEnded {
            videoEnded = false
            seek(to: 0)
        }
        player.playImmediately(atRate: Float(settings.playbackSpeed))
        isPlaying = true
        updateNowPlayingPlayback()
        playerLog.notice("[audioSession] audible playback resumed for \(reason)")
        return true
    }

    func handleAudioInterruption(
        type: AVAudioSession.InterruptionType,
        options: AVAudioSession.InterruptionOptions = []
    ) {
        switch type {
        case .began:
            // Duplicate began notifications are possible while voice input negotiates
            // its route. Never overwrite the original was-playing snapshot with the
            // paused state from a later duplicate.
            let action = audioInterruptionState.began(
                wasPlaying: isPlaying || player.rate > 0
            )
            guard action == .pauseAndYield else {
                playerLog.notice("[interruption] duplicate began ignored")
                return
            }
            // A previously scheduled stall retry must never restart playback while
            // the microphone owns the route.
            exhaustiveRetryTask?.cancel()
            exhaustiveRetryTask = nil
            player.pause()
            isPlaying = false
            updateNowPlayingPlayback()
            _ = Self.deactivatePlaybackAudioSession(reason: "interruption began")
            playerLog.notice("[interruption] began — player paused and route yielded; wasPlaying=\(self.wasPlayingBeforeInterruption)")

        case .ended:
            let action = audioInterruptionState.ended(
                shouldResume: options.contains(.shouldResume)
            )
            guard action != .ignore else {
                playerLog.notice("[interruption] ended without active interruption — ignored")
                return
            }
            let shouldResume = action == .activateAndResume
            playerLog.notice("[interruption] ended — shouldResume=\(shouldResume)")

            if shouldResume,
               Self.activatePlaybackAudioSession(reason: "interruption ended") {
                if resumeAudiblePlayback(reason: "interruption ended") {
                    audioInterruptionResumeCount &+= 1
                } else {
                    player.pause()
                    isPlaying = false
                    _ = Self.deactivatePlaybackAudioSession(reason: "interruption resume unavailable")
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

    func handleAudioRouteChange(reason: AVAudioSession.RouteChangeReason) {
        guard (reason == .oldDeviceUnavailable || reason == .noSuitableRouteForCategory),
              !isHandlingAudioInterruption else { return }
        audioInterruptionState.invalidatePendingRecovery()
        player.pause()
        isPlaying = false
        updateNowPlayingPlayback()
        _ = Self.deactivatePlaybackAudioSession(reason: "old route unavailable")
        playerLog.notice("[audioSession] old output route unavailable — staying paused")
    }

    func handleMediaServicesLost() {
        guard !isHandlingAudioInterruption else { return }
        audioInterruptionState.invalidatePendingRecovery()
        wasPlayingBeforeMediaServicesLoss = isPlaying || player.rate > 0
        player.pause()
        isPlaying = false
        updateNowPlayingPlayback()
        playerLog.notice("[audioSession] media services lost — paused; wasPlaying=\(self.wasPlayingBeforeMediaServicesLoss)")
    }

    func handleMediaServicesReset() {
        audioInterruptionState.invalidatePendingRecovery()
        let shouldResume = !isHandlingAudioInterruption
            && (wasPlayingBeforeMediaServicesLoss || isPlaying || player.rate > 0)
        wasPlayingBeforeMediaServicesLoss = false
        player.pause()
        isPlaying = false
        updateNowPlayingPlayback()

        // During an interruption only restore the category. Activating here would
        // steal the microphone route; the matching .ended notification owns resume.
        guard !isHandlingAudioInterruption else {
            _ = Self.configurePlaybackAudioSession(reason: "media services reset during interruption")
            return
        }

        if shouldResume,
           Self.activatePlaybackAudioSession(reason: "media services reset"),
           resumeAudiblePlayback(reason: "media services reset") {
            return
        }

        _ = Self.configurePlaybackAudioSession(reason: "media services reset while paused")
        if shouldResume {
            _ = Self.deactivatePlaybackAudioSession(reason: "media services reset resume failed")
        }
    }

    func setupAudioSessionObserver() {
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

        audioSessionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            guard let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
            let optionsValue = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            Task { @MainActor [weak self] in
                self?.handleAudioInterruption(type: type, options: options)
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
    }

    func setupRemoteCommandCenter() {
        // stop() removes audio observers. Re-registering here keeps every new load
        // covered while setupAudioSessionObserver() remains idempotent.
        setupAudioSessionObserver()
        let center = MPRemoteCommandCenter.shared()
        // Remove any existing targets first so this function is safe to call
        // multiple times (e.g. early in loadAsync AND at readyToPlay) without
        // accumulating duplicate handlers.
        center.playCommand.removeTarget(nil)
        center.pauseCommand.removeTarget(nil)
        center.togglePlayPauseCommand.removeTarget(nil)
        center.skipForwardCommand.removeTarget(nil)
        center.skipBackwardCommand.removeTarget(nil)
        center.changePlaybackPositionCommand.removeTarget(nil)
        center.nextTrackCommand.removeTarget(nil)
        center.previousTrackCommand.removeTarget(nil)

        center.playCommand.addTarget { [weak self] _ in
            guard Self.activatePlaybackAudioSession(reason: "Lock Screen Play") else {
                return .commandFailed
            }
            Task { @MainActor [weak self] in
                self?.resumeAudiblePlayback(reason: "Lock Screen Play")
            }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.player.pause()
                self?.isPlaying = false
                self?.updateNowPlayingPlayback()
            }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            // Activation is harmless for the pause half of Toggle and necessary for
            // the play half; doing it synchronously prevents a silent fake-resume.
            guard Self.activatePlaybackAudioSession(reason: "Lock Screen Toggle") else {
                return .commandFailed
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.isPlaying {
                    self.player.pause()
                    self.isPlaying = false
                    self.updateNowPlayingPlayback()
                } else {
                    self.resumeAudiblePlayback(reason: "Lock Screen Toggle")
                }
            }
            return .success
        }
        center.skipForwardCommand.preferredIntervals = [10]
        center.skipForwardCommand.addTarget { [weak self] event in
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? 10
            Task { @MainActor [weak self] in self?.seekRelative(seconds: interval) }
            return .success
        }
        center.skipBackwardCommand.preferredIntervals = [10]
        center.skipBackwardCommand.addTarget { [weak self] event in
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? 10
            Task { @MainActor [weak self] in self?.seekRelative(seconds: -interval) }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            let position = (event as? MPChangePlaybackPositionCommandEvent)?.positionTime ?? 0
            Task { @MainActor [weak self] in self?.seek(to: position) }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in self?.playNext() }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in self?.playPrevious() }
            return .success
        }
    }

    func updateNowPlayingInfo() {
        let video = playerInfo?.video ?? currentVideo
        guard let video else {
            nowPlayingInfoCache = [:]
            setNowPlayingInfo(nil)
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: video.title,
            MPMediaItemPropertyArtist: video.channelTitle,
            MPNowPlayingInfoPropertyMediaType: NSNumber(value: MPNowPlayingInfoMediaType.video.rawValue),
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
                Task { [weak self, url = thumbURL, videoID = video.id] in
                    guard let (data, _) = try? await URLSession.shared.data(from: url),
                          let image = UIImage(data: data) else { return }
                    await MainActor.run { [weak self] in
                        guard let self, self.cachedArtworkVideoID == videoID else { return }
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
        nowPlayingInfoCache[MPNowPlayingInfoPropertyElapsedPlaybackTime] = NSNumber(value: currentTime)
        nowPlayingInfoCache[MPNowPlayingInfoPropertyPlaybackRate] = NSNumber(value: isPlaying ? Double(player.rate) : 0.0)
        setNowPlayingInfo(nowPlayingInfoCache)
    }

    func clearNowPlayingInfo() {
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
    }
}
#endif
