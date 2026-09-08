import AVFoundation
import iPocketTubeCore

extension PlaybackViewModel {
    /// The single rate-writing boundary for asynchronous media preparation.
    /// Returning false for a stale item must never pause the newer item.
    @discardableResult
    func requestPlaybackStart(expectedItem: AVPlayerItem? = nil, rate: Float? = nil,
                              reason: String = "media prepared") -> Bool {
        guard !Task.isCancelled else { return false }
        if let expectedItem, player.currentItem !== expectedItem { return false }
        guard player.currentItem != nil, audioInterruptionState.allowsAutomaticPlayback else {
            player.pause()
            isPlaying = false
            return false
        }
        #if os(iOS)
        guard !localDubbingManager.isPlaying else {
            player.pause()
            isPlaying = false
            return false
        }
        #endif
        #if canImport(UIKit)
        guard Self.activatePlaybackAudioSession(reason: reason) else {
            player.pause()
            isPlaying = false
            return false
        }
        #endif
        player.playImmediately(atRate: rate ?? Float(settings.playbackSpeed))
        isPlaying = true
        return true
    }

    /// Last-line protection for system/KVO and legacy rate writers. It does not
    /// infer silence from quiet media, nor invent a new playback intent.
    @discardableResult
    func enforcePlaybackAuthority() -> Bool {
        guard !audioInterruptionState.allowsAutomaticPlayback else { return false }
        player.pause()
        isPlaying = false
        return true
    }
}
