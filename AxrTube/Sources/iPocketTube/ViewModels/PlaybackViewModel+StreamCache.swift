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
            preferredMaxHeight: maxHeight > 0 ? maxHeight : nil,
            audioOnly: wantsAudioOnly(video)
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

    var currentItemIsProxied: Bool {
        (player.currentItem?.asset as? AVURLAsset)?.url.host == "127.0.0.1"
    }

    private func applyCacheProgress(_ progress: StreamCacheProgress?) {
        let shown = currentItemIsProxied ? progress : nil
        let ranges = shown?.ranges ?? []
        let complete = shown?.isComplete ?? false
        if cachedTimeRanges != ranges { cachedTimeRanges = ranges }
        if isFullyCached != complete { isFullyCached = complete }
        if let shown { prefetchUpNextIfReady(shown) }
        // A saved video downloading through the player reports its progress.
        if let id = currentVideo?.id, shown != nil, PinnedStreamLibrary.shared.entry(id) != nil {
            let fraction = cachedFraction
            let audioOnly = isAudioOnlyMode
            Task {
                await PinnedStreamLibrary.shared.updateFromPlayback(
                    id, progress: fraction, isComplete: complete, audioOnlySession: audioOnly
                )
            }
        }
    }

    /// Opt-in («Загружать следующее видео»): once the current video is safe
    /// (fully cached or 3+ minutes ahead of the playhead), download the
    /// first minute of the next «Далее» video.
    private func prefetchUpNextIfReady(_ progress: StreamCacheProgress) {
        guard settings.prefetchUpNextEnabled, let current = currentVideo,
              upNextPrefetchedFor != current.id else { return }
        let ahead = progress.ranges.first { $0.contains(currentTime) }.map { $0.upperBound - currentTime } ?? 0
        guard progress.isComplete || ahead >= 180 else { return }
        upNextPrefetchedFor = current.id
        let api = api
        let maxHeight = settings.preferredQuality == .auto ? nil : settings.preferredQuality.maxHeight
        Task { [weak self] in
            guard let next = await self?.upNextCandidate(), next.id != current.id, !next.isLive,
                  let info = try? await api.fetchStartupPlayerInfo(videoId: next.id),
                  let hls = info.hlsURL else { return }
            playerLog.notice("[stream-cache] prefetching up next \(next.id)")
            await HLSCachingProxy.shared.prefetchHead(
                videoID: next.id, masterURL: hls,
                headers: [
                    "User-Agent": InnerTubeClients.Web.userAgent,
                    "Origin": "https://www.youtube.com",
                    "Referer": "https://www.youtube.com/",
                ],
                preferredMaxHeight: maxHeight
            )
        }
    }

    /// What «Далее» would play: the next queue item, else the first suggestion.
    func upNextCandidate() async -> Video? {
        if let index = currentVideo?.playlistIndex, currentVideo?.playlistId == CurrentQueueStore.playlistID,
           let next = await CurrentQueueStore.shared.videoAt(index: index + 1) {
            return next
        }
        return relatedVideos.first
    }

    /// Share of the current video that is on disk (0…1), as on the bar.
    var cachedFraction: Double {
        guard duration > 0 else { return 0 }
        if isFullyCached { return 1 }
        return min(cachedTimeRanges.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) } / duration, 1)
    }

    /// Plays a previously cached or saved stream without YouTube metadata —
    /// used offline or when the metadata request fails.
    func playSavedStreamIfAvailable(_ video: Video) async -> Bool {
        guard let data = await StreamSegmentCache.shared.named(video: video.id, name: StreamSource.fileName),
              let source = try? JSONDecoder().decode(StreamSource.self, from: data),
              !player.isExternalPlaybackActive,
              let local = await HLSCachingProxy.shared.startSession(
                  videoID: video.id, masterURL: source.master, headers: source.headers, preferredMaxHeight: nil,
                  audioOnly: wantsAudioOnly(video)
              ) else { return false }
        ensureCacheProgressUpdates()
        streamCacheDirectSource = (source.master, source.headers)
        isAudioOnlyMode = wantsAudioOnly(video)
        if let known = video.duration, known > 0 { duration = known }
        let item = AVPlayerItem(asset: AVURLAsset(url: local))
        item.preferredForwardBufferDuration = PlaybackBufferPolicy.videoForwardBuffer
        playLocalItem(item, video: video, label: "saved stream \(video.id)")
        return true
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

    // MARK: Data saver (audio only)

    /// Sound only for `video`: the user's per-video choice wins, otherwise
    /// «Экономия трафика» decides (always, or on a mobile network).
    func wantsAudioOnly(_ video: Video) -> Bool {
        if audioForcedFor == video.id { return true }
        return DataSaverPolicy.streamsAudioOnly(
            mode: settings.dataSaver, audioOnlySetting: settings.audioOnlyMode,
            onMobileNetwork: NetworkPathObserver.shared.isMobile,
            videoRequested: videoRequestedFor == video.id
        )
    }

    /// Recomputes the mode for the current video and, when it changed while a
    /// cached stream is playing, restarts the stream at the same position so
    /// the video track starts or stops downloading.
    func applyAudioOnlyDecision() {
        guard let video = currentVideo else {
            isAudioOnlyMode = settings.audioOnlyMode || settings.dataSaver == .always
            return
        }
        let wanted = video.localMediaKind == .audio || wantsAudioOnly(video)
        guard wanted != isAudioOnlyMode else { return }
        isAudioOnlyMode = wanted
        guard currentItemIsProxied else { return }
        let time = currentTime
        playerLog.notice("[data-saver] audioOnly=\(wanted) — restarting stream at \(Int(time))s")
        if playerInfo?.hlsURL != nil {
            let quality = settings.preferredQuality
            Task { await self.reloadHLSItem(seekTo: time, quality: quality) }
        } else {
            Task {
                if await self.playSavedStreamIfAvailable(video), time > 1 { self.seek(to: time) }
            }
        }
    }

    /// Per-video switch from the player: picture on or off for this video.
    func setVideoWanted(_ wanted: Bool) {
        guard let id = currentVideo?.id else { return }
        videoRequestedFor = wanted ? id : nil
        audioForcedFor = wanted ? nil : id
        applyAudioOnlyDecision()
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
        info: PlayerInfo?, masterURL: URL, headers: [String: String], maxHeight: Int?,
        audioOnly: Bool, externalPlayback: Bool
    ) async -> URL {
        guard let video = info?.video, !video.isLive, !externalPlayback,
              let local = await HLSCachingProxy.shared.startSession(
                  videoID: video.id, masterURL: masterURL, headers: headers, preferredMaxHeight: maxHeight,
                  audioOnly: audioOnly
              ) else {
            await HLSCachingProxy.shared.endSession()
            return masterURL
        }
        return local
    }
}
