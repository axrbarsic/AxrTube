import AVFoundation
import os
#if canImport(UIKit)
import MediaPlayer
#endif
import iPocketTubeCore

private let playerLog = CrashlyticsLogger(category: "Player")

// MARK: - Transport Controls & Scrubbing

extension PlaybackViewModel {

    public func togglePlayPause() {
        if videoEnded {
            videoEnded = false
            seek(to: 0)
            #if canImport(UIKit)
            performUserPlay(reason: "Player Controls Replay")
            #else
            _ = audioInterruptionState.userRequestedPlay()
            requestPlaybackStart(reason: "replay")
            #endif
            showControls()
            #if canImport(UIKit)
            updateNowPlayingPlayback()
            #endif
            return
        }
        #if canImport(UIKit)
        if isPlaying {
            performUserPause(reason: "Player Controls Pause")
        } else {
            performUserPlay(reason: "Player Controls Play")
        }
        #else
        if isPlaying {
            audioInterruptionState.userPaused()
            player.pause()
            isPlaying = false
        } else {
            _ = audioInterruptionState.userRequestedPlay()
            requestPlaybackStart(reason: "play control")
        }
        #endif
        showControls()
        #if canImport(UIKit)
        updateNowPlayingPlayback()
        #endif
    }

    // MARK: - Scrubbing (slider drag)

    /// Called when the user starts dragging the progress slider.
    public func beginScrubbing() {
        // Guard against the spurious onEditingChanged(true) that SwiftUI's Slider
        // fires right after commitScrub() triggers a binding re-evaluation.
        let sinceCommit = Date.now.timeIntervalSince(lastCommitScrubTime)
        guard sinceCommit > 0.5 else {
            playerLog.debug("[scrub] beginScrubbing IGNORED (spurious, \(String(format: "%.3f", sinceCommit))s since commit — threshold=0.5s)")
            return
        }
        playerLog.debug("[scrub] beginScrubbing at \(String(format: "%.1f", self.currentTime))s — sinceCommit=\(String(format: "%.3f", sinceCommit))s isScrubbing=\(self.isScrubbing) controlsVisible=\(self.controlsVisible)")
        seekDebounceTask?.cancel()
        isScrubbing = true
        scrubTime = currentTime
        playerLog.debug("[scrub] beginScrubbing done — isScrubbing=\(self.isScrubbing)")
    }

    /// Called on every incremental slider position update while dragging.
    /// Only updates the local `scrubTime` — does NOT seek AVPlayer, preventing
    /// rapid-seek stalls. Seeking happens only on `commitScrub`.
    public func updateScrub(to time: TimeInterval) {
        scrubTime = time
    }

    /// Called when the user releases the slider. Issues a single precise seek.
    public func commitScrub() {
        // SwiftUI's Slider fires onEditingChanged(false) on initialization (when the
        // view first renders), before the user has ever touched it. Guard here so that
        // spurious call doesn't (a) call showControls() at load time, or (b) poison
        // lastCommitScrubTime and block the user's first real scrub attempt via the
        // debounce guard in beginScrubbing().
        guard isScrubbing else { return }
        seekDebounceTask?.cancel()  // release-seek supersedes any pending debounce
        let target = scrubTime
        playerLog.debug("[scrub] commitScrub to \(String(format: "%.1f", target))s — isScrubbing=\(self.isScrubbing) controlsVisible=\(self.controlsVisible)")
        lastCommitScrubTime = .now
        isScrubbing = false
        seek(to: target)
        showControls()
        playerLog.debug("[scrub] commitScrub done — isScrubbing=\(self.isScrubbing) controlsVisible=\(self.controlsVisible)")
    }

    /// Issues a seek to the given time. Does NOT show controls — callers that
    /// want the overlay to appear (user-initiated gestures) must call
    /// `showControls()` themselves after this.
    public func seek(to time: TimeInterval) {
        player.seek(
            to: CMTime(seconds: time, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.currentTime = time }
        }
    }

    public func seekRelative(seconds: TimeInterval) {
        seek(to: max(0, currentTime + seconds))
        showControls()
    }

    public func setPlaybackSpeed(_ speed: Double) {
        // Setting player.rate to a non-zero value on a paused AVPlayer restarts
        // playback — only apply the rate while actively playing.
        if isPlaying {
            requestPlaybackStart(rate: Float(speed), reason: "playback speed")
        }
    }

    /// Called when the user begins a long-press on the video surface (controls hidden).
    /// Temporarily boosts playback to 2× until `endHoldSpeed()` is called.
    public func beginHoldSpeed() {
        guard isPlaying, !isHoldingToSpeed else { return }
        isHoldingToSpeed = true
        requestPlaybackStart(rate: 2.0, reason: "hold speed")
        playerLog.notice("[hold-speed] began — boosting to 2×")
    }

    /// Called when the user lifts their finger after a long-press speed boost.
    /// Restores playback to the configured speed.
    public func endHoldSpeed() {
        guard isHoldingToSpeed else { return }
        isHoldingToSpeed = false
        if isPlaying {
            requestPlaybackStart(reason: "restore speed")
        }
        playerLog.notice("[hold-speed] ended — restored to \(self.settings.playbackSpeed)×")
    }
}
