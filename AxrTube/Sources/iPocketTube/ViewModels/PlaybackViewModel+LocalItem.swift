import AVFoundation
#if canImport(UIKit)
import UIKit
#endif
import iPocketTubeCore

private let playerLog = CrashlyticsLogger(category: "Player")

// MARK: - Local playback (downloaded files and saved streams)

extension PlaybackViewModel {
    /// Plays an item that needs no YouTube metadata request: a downloaded file
    /// or a saved stream served by the local cache proxy.
    func playLocalItem(_ item: AVPlayerItem, video: Video, label: String) {
        item.audioTimePitchAlgorithm = .spectral
        // Wire up observers BEFORE replaceCurrentItem (task-80 rule).
        itemObserverTask?.cancel()
        itemObserverTask = Task { [weak self] in
            for await status in item.statusStream {
                guard let self, !Task.isCancelled,
                      self.player.currentItem === item,
                      self.currentVideo?.id == video.id else { return }
                switch status {
                case .readyToPlay:
                    playerLog.notice("[benchmark] readyToPlay — local-file — videoId=\(video.id) title=\(video.title)")
                    self.loadAudioTracks(from: item)
                    self.isLoading = false
                case .failed:
                    playerLog.error("❌ local-file AVPlayerItem failed: \(String(describing: item.error))")
                    self.error = item.error
                case .unknown:
                    break
                @unknown default:
                    break
                }
            }
        }
        player.replaceCurrentItem(with: item)
        endObserverTask?.cancel()
        endObserverTask = Task { [weak self] in
            let notifications = NotificationCenter.default.notifications(
                named: AVPlayerItem.didPlayToEndTimeNotification,
                object: item
            )
            for await _ in notifications {
                guard let self, !Task.isCancelled, self.player.currentItem === item else { return }
                self.handlePlaybackEnd()
            }
        }
        stallObserverTask?.cancel()
        stallObserverTask = Task { @MainActor [weak self] in
            let notifications = NotificationCenter.default.notifications(
                named: AVPlayerItem.playbackStalledNotification,
                object: item
            )
            for await _ in notifications {
                guard let self, !Task.isCancelled else { return }
                self.stallCount += 1
                let t = Int(self.currentTime)
                playerLog.notice("[stall] AVPlayerItemPlaybackStalled at t=\(t)s stall#\(self.stallCount) video=\(self.currentVideo?.id ?? "unknown")")
                let stallError = NSError(
                    domain: "iPocketTube.PlaybackStall",
                    code: 0,
                    userInfo: [NSLocalizedDescriptionKey: "AVPlayerItemPlaybackStalled at t=\(t)s (stall #\(self.stallCount))"]
                )
                playerLog.recordNonFatal(stallError, userInfo: [
                    "video_id":       self.currentVideo?.id ?? "unknown",
                    "stall_at_time":  String(t),
                    "stall_count":    String(self.stallCount),
                    "video_duration": String(Int(self.duration)),
                    "stall_trigger":  "AVPlayerItemPlaybackStalled"
                ])
                self.beginStallRecovery(item: item, source: "local stalled")
            }
        }
        #if canImport(UIKit)
        setupRemoteCommandCenter()
        #endif
        requestPlaybackStart(expectedItem: item, reason: "local-file playback")
        // Downloaded videos have no related videos — clear any stale state from a
        // previous YouTube session so autoplay does not fire a YouTube video when
        // the download ends. (Bug #224: wrong video played after local file ends.)
        relatedVideos = []
        hasNext = false
        #if canImport(UIKit)
        UIApplication.shared.isIdleTimerDisabled = true
        updateNowPlayingInfo()
        #endif
        playerLog.notice("[loadAsync] local playback: \(label)")
    }
}
