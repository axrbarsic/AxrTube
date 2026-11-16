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
        ensureCacheProgressUpdates()
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

    /// Keeps the progress bar's layers live: the disk layer is pushed by the
    /// proxy the moment a segment is saved; the in-memory buffer (used only
    /// without the cache) is sampled 4× a second.
    func ensureCacheProgressUpdates() {
        guard cacheProgressTask == nil else { return }
        cacheProgressTask = Task { @MainActor [weak self] in
            let updates = await HLSCachingProxy.shared.progressUpdates()
            for await progress in updates {
                guard let self else { return }
                self.applyCacheProgress(progress)
            }
        }
        bufferSampleTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.refreshBufferedRanges()
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    private var currentItemIsProxied: Bool {
        (player.currentItem?.asset as? AVURLAsset)?.url.host == "127.0.0.1"
    }

    private func applyCacheProgress(_ progress: StreamCacheProgress?) {
        let shown = currentItemIsProxied ? progress : nil
        let ranges = shown?.ranges ?? []
        let complete = shown?.isComplete ?? false
        if cachedTimeRanges != ranges { cachedTimeRanges = ranges }
        if isFullyCached != complete { isFullyCached = complete }
    }

    private func refreshBufferedRanges() {
        let buffered: [ClosedRange<Double>] = currentItemIsProxied ? [] : (player.currentItem?.loadedTimeRanges ?? []).compactMap {
            let r = $0.timeRangeValue
            let start = CMTimeGetSeconds(r.start), end = CMTimeGetSeconds(CMTimeRangeGetEnd(r))
            return start.isFinite && end.isFinite && end > start ? start...end : nil
        }
        if bufferedTimeRanges != buffered { bufferedTimeRanges = buffered }
        // An item swap (AirPlay, fallback) must drop the disk layer at once.
        if !currentItemIsProxied, !cachedTimeRanges.isEmpty || isFullyCached {
            cachedTimeRanges = []
            isFullyCached = false
        }
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
