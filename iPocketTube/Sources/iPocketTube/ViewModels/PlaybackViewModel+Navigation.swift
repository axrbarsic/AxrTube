import AVFoundation
import os
import iPocketTubeCore

private let playerLog = CrashlyticsLogger(category: "Player")

// MARK: - Queue, History & Chapter Navigation

extension PlaybackViewModel {

    // MARK: - Next-video prefetch

    /// Prefetches the queue video at `index` in the background so its PlayerInfo
    /// is warm in `VideoPreloadCache` before `load(video:)` is called for it.
    /// Uses `.immediate` priority so it jumps ahead of speculative card prefetches.
    /// Safe to call multiple times for the same video — the cache deduplicates.
    func prefetchQueueVideo(at index: Int) {
        let sponsorCats = settings.activeSponsorCategories
        let token = currentAuthToken
        // Pre-warm BotGuardWebViewRunner for rqh=1 queue videos — fire once, no-ops when ready.
        #if canImport(WebKit)
        if !BotGuardWebViewRunner.shared.isReady {
            Task.detached(priority: .background) {
                await BotGuardWebViewRunner.shared.prepare()
            }
        }
        #endif
        Task(priority: .userInitiated) { [weak self] in
            guard let next = await CurrentQueueStore.shared.videoAt(index: index) else { return }
            playerLog.notice("[prefetch] next-queue video index=\(index) id=\(next.id)")
            await VideoPreloadCache.shared.prefetch(
                videoId: next.id,
                sponsorCategories: sponsorCats,
                authToken: token,
                priority: .immediate
            )
            // Also prefetch the one after — avoids a cold start if the user
            // taps "next" quickly before the first prefetch completes.
            guard let _ = self else { return }
            let afterNext = await CurrentQueueStore.shared.videoAt(index: index + 1)
            if let afterNext {
                playerLog.notice("[prefetch] next+1 queue video index=\(index + 1) id=\(afterNext.id)")
                await VideoPreloadCache.shared.prefetch(
                    videoId: afterNext.id,
                    sponsorCategories: sponsorCats,
                    authToken: token,
                    priority: .visible   // beats home-feed card prefetches so it finishes before the user taps twice
                )
            }
        }
    }

    // MARK: - Navigation

    /// Play the next related video. Advances through the Current Queue if one is
    /// active; otherwise falls back to the first related (suggestion) video.
    public func playNext() {
        if let idx = currentVideo?.playlistIndex,
           currentVideo?.playlistId == CurrentQueueStore.playlistID {
            Task {
                if let next = await CurrentQueueStore.shared.videoAt(index: idx + 1) {
                    playerLog.notice("playNext (queue): index=\(idx + 1) id=\(next.id)")
                    prefetchQueueVideo(at: idx + 2)
                    CrashlyticsLogger.setIntendedVideo(id: next.id, title: next.title)
                    load(video: next)
                } else {
                    playerLog.notice("playNext (queue): exhausted at index=\(idx), clearing")
                    await CurrentQueueStore.shared.clear()
                    playNextFromSuggestions()
                }
            }
            return
        }
        playNextFromSuggestions()
    }

    private func playNextFromSuggestions() {
        guard let next = relatedVideos.first else { return }
        playerLog.notice("playNext: id=\(next.id)")
        CrashlyticsLogger.setIntendedVideo(id: next.id, title: next.title)
        load(video: next)
    }

    /// Play the most recently played video from the history stack.
    /// Pops the last entry from history; load() will push the current video back so
    /// the user can navigate forward again with playNext() or via suggestions.
    public func playPrevious() {
        guard !history.isEmpty else { return }
        let prev = history.removeLast()
        hasPrevious = !history.isEmpty
        playerLog.notice("playPrevious: id=\(prev.id)")
        CrashlyticsLogger.setIntendedVideo(id: prev.id, title: prev.title)
        load(video: prev)
    }

    /// Seek to the start of the next chapter.
    public func skipToNextChapter() {
        guard let next = chapters.first(where: { $0.startTime > currentTime }) else { return }
        seek(to: next.startTime)
        showControls()
    }

    /// Seek to the start of the current chapter (if >3 s in) or to the previous chapter.
    public func skipToPreviousChapter() {
        guard let current = currentChapter else { return }
        if currentTime - current.startTime > 3 {
            seek(to: current.startTime)
        } else if let prev = chapters.last(where: { $0.startTime < current.startTime }) {
            seek(to: prev.startTime)
        }
        showControls()
    }

    public func handlePlaybackEnd() {
        if settings.loopEnabled {
            player.seek(to: .zero)
            player.rate = Float(settings.playbackSpeed)
            return
        }
        if let idx = currentVideo?.playlistIndex,
           currentVideo?.playlistId == CurrentQueueStore.playlistID {
            Task {
                if settings.queueShuffleEnabled {
                    let remaining = await CurrentQueueStore.shared.remainingVideos(after: idx)
                    if let pick = remaining.randomElement() {
                        playerLog.notice("Autoplay (queue, shuffle): random id=\(pick.id)")
                        CrashlyticsLogger.setIntendedVideo(id: pick.id, title: pick.title)
                        load(video: pick)
                    } else {
                        playerLog.notice("Autoplay (queue, shuffle): exhausted, falling back to recommendations")
                        await CurrentQueueStore.shared.clear()
                        autoplayFromRecommendations()
                    }
                } else {
                    if let next = await CurrentQueueStore.shared.videoAt(index: idx + 1) {
                        playerLog.notice("Autoplay (queue): index=\(idx + 1) id=\(next.id)")
                        prefetchQueueVideo(at: idx + 2)
                        CrashlyticsLogger.setIntendedVideo(id: next.id, title: next.title)
                        load(video: next)
                    } else {
                        playerLog.notice("Autoplay (queue): exhausted, falling back to recommendations")
                        await CurrentQueueStore.shared.clear()
                        autoplayFromRecommendations()
                    }
                }
            }
            return
        }
        autoplayFromRecommendations()
    }

    /// Falls back to a recommended video when there's no active queue (or the
    /// queue has just been exhausted): shuffles from `relatedVideos` if shuffle
    /// is enabled, otherwise autoplays the first related video if autoplay is
    /// enabled, otherwise marks the video as ended.
    private func autoplayFromRecommendations() {
        if settings.shuffleEnabled, !relatedVideos.isEmpty {
            let pick = relatedVideos[Int.random(in: 0..<relatedVideos.count)]
            playerLog.notice("Shuffle: loading id=\(pick.id)")
            CrashlyticsLogger.setIntendedVideo(id: pick.id, title: pick.title)
            load(video: pick)
            return
        }
        guard settings.autoplayEnabled, let next = relatedVideos.first else {
            videoEnded = true
            return
        }
        playerLog.notice("Autoplay: loading next video id=\(next.id)")
        CrashlyticsLogger.setIntendedVideo(id: next.id, title: next.title)
        load(video: next)
    }
}
