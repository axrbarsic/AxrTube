import AVFoundation
import iPocketTubeCore

private let playerLog = CrashlyticsLogger(category: "Player")

// MARK: - Weak-network stream cache

extension PlaybackViewModel {
    /// Local proxy URL for VOD HLS, or the origin URL when the cache does not
    /// apply (live, AirPlay — the receiver cannot reach the phone's loopback —
    /// or the loopback server failed to start).
    func streamCachePlaybackURL(
        for video: Video, masterURL: URL, headers: [String: String], isHLS: Bool, maxHeight: Int
    ) async -> URL {
        streamCacheDirectSource = nil
        guard isHLS, !video.isLive, !player.isExternalPlaybackActive else {
            endStreamCacheSession()
            return masterURL
        }
        guard let local = await HLSCachingProxy.shared.startSession(
            videoID: video.id, masterURL: masterURL, headers: headers,
            preferredMaxHeight: maxHeight > 0 ? maxHeight : nil
        ) else {
            playerLog.notice("[stream-cache] loopback unavailable — playing origin directly")
            return masterURL
        }
        streamCacheDirectSource = (masterURL, headers)
        return local
    }

    func endStreamCacheSession() {
        streamCacheDirectSource = nil
        Task { await HLSCachingProxy.shared.endSession() }
    }

    /// AirPlay video is fetched by the receiver, which cannot reach 127.0.0.1:
    /// rebuild the item from the origin through the regular quality path
    /// (it seeks back and rewires observers).
    func switchToOriginForExternalPlayback() {
        guard let current = player.currentItem,
              (current.asset as? AVURLAsset)?.url.host == "127.0.0.1" else { return }
        playerLog.notice("[stream-cache] external playback — switching to origin at \(Int(self.currentTime))s")
        streamCacheDirectSource = nil
        let quality = settings.preferredQuality
        let time = currentTime
        Task { await self.reloadHLSItem(seekTo: time, quality: quality) }
    }
}

/// Shared decision for every HLS item builder: proxy VOD through the cache
/// unless the receiver is external (AirPlay) or the video is live.
enum StreamCacheRouting {
    static func playbackURL(
        info: PlayerInfo?, masterURL: URL, headers: [String: String], maxHeight: Int?, externalPlayback: Bool
    ) async -> URL {
        guard let video = info?.video, !video.isLive, !externalPlayback,
              let local = await HLSCachingProxy.shared.startSession(
                  videoID: video.id, masterURL: masterURL, headers: headers, preferredMaxHeight: maxHeight
              ) else {
            await HLSCachingProxy.shared.endSession()
            return masterURL
        }
        return local
    }
}
