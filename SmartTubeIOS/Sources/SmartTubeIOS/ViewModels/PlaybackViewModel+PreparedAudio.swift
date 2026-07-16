#if os(iOS)
import AVFoundation
import MediaPlayer
import SmartTubeIOSCore
import UIKit

extension PlaybackViewModel {
    /// Installs a direct audio item supplied by the progressive offline cache.
    /// This bypasses every video/HLS/IFrame/end-card/ad path while retaining the
    /// proven AVAudioSession, interruption, remote-command, and recovery graph.
    func loadPreparedAudio(item: AVPlayerItem, video: Video, startImmediately: Bool) {
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
                    let saved = await VideoStateStore.shared.state(for: video.id)?.position ?? 0
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

        player.automaticallyWaitsToMinimizeStalling = true
        player.replaceCurrentItem(with: item)
        UIApplication.shared.isIdleTimerDisabled = false
    }

    func startPreparedAudioPlayback() {
        guard player.currentItem != nil else { return }
        _ = Self.activatePlaybackAudioSession(reason: "audio-first initial buffer ready")
        setupRemoteCommandCenter()
        player.playImmediately(atRate: Float(settings.playbackSpeed))
        isPlaying = true
        isLoading = false
        updateNowPlayingInfo()
        updateNowPlayingPlayback()
    }
}
#endif
