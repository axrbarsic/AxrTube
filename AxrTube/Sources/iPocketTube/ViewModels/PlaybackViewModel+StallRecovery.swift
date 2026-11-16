import AVFoundation
import iPocketTubeCore

private let playerLog = CrashlyticsLogger(category: "Player")

// MARK: - Weak-network stall recovery

extension PlaybackViewModel {
    /// Watches a stalled item until it plays again. Seeks in place or reloads
    /// only when the network is up and no bytes arrive (see
    /// `StallRecoveryPolicy`); while offline or on a slow link it waits, so
    /// the partly downloaded segment and the forward buffer are kept.
    /// Single-flight: a new stall on the same item reuses the running watcher.
    func beginStallRecovery(item: AVPlayerItem, source: String) {
        if stallRecoveryTask != nil, stallRecoveryItem === item { return }
        stallRecoveryTask?.cancel()
        stallRecoveryItem = item
        stallRecoveryTask = Task { @MainActor [weak self, weak item] in
            defer { self?.finishStallRecovery(item: item) }
            guard let item else { return }
            await self?.runStallRecovery(item: item, source: source)
        }
    }

    func cancelStallRecovery() {
        stallRecoveryTask?.cancel()
        stallRecoveryTask = nil
        stallRecoveryItem = nil
    }

    private func finishStallRecovery(item: AVPlayerItem?) {
        guard stallRecoveryItem === item else { return }
        stallRecoveryTask = nil
        stallRecoveryItem = nil
    }

    private func runStallRecovery(item: AVPlayerItem, source: String) async {
        let started = Date()
        var lastEnd = Self.bufferedEnd(of: item)
        var lastGrowth = started
        var lastNudge = started
        var nudges = 0
        // Bounded: after 15 minutes the regular failure paths take over.
        while !Task.isCancelled, Date().timeIntervalSince(started) < 900 {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, player.currentItem === item, !isQualityChangePending,
                  !isSwappingItem, !isHandlingAudioInterruption else { return }
            if player.timeControlStatus == .playing { return }

            let end = Self.bufferedEnd(of: item)
            if end > lastEnd + 0.05 { lastEnd = end; lastGrowth = Date() }
            let ahead = end - currentTime
            // Enough data arrived (or the network came back): resume.
            if player.rate == 0, ahead >= 3 || item.isPlaybackLikelyToKeepUp {
                if requestPlaybackStart(expectedItem: item, reason: "\(source) buffered resume") {
                    playerLog.notice("[stall] \(source): resumed with \(Int(ahead))s buffered")
                }
                continue
            }

            let now = Date()
            switch StallRecoveryPolicy.decide(
                networkAvailable: NetworkPathObserver.shared.isAvailable,
                secondsSinceBufferGrowth: now.timeIntervalSince(lastGrowth),
                secondsSinceLastNudge: now.timeIntervalSince(lastNudge),
                nudges: nudges,
                secondsStalled: now.timeIntervalSince(started)
            ) {
            case .wait:
                continue
            case .nudge:
                nudges += 1
                lastNudge = now
                lastGrowth = now
                let t = currentTime
                playerLog.notice("[stall] \(source): no data for \(StallRecoveryPolicy.progressWindow)s online — nudge#\(nudges) seek \(Int(t))s")
                await player.seek(
                    to: CMTime(seconds: t, preferredTimescale: 600),
                    toleranceBefore: .zero,
                    toleranceAfter: CMTime(seconds: 1, preferredTimescale: 600)
                )
                guard player.currentItem === item else { return }
                requestPlaybackStart(expectedItem: item, reason: "\(source) nudge")
            case .escalate:
                guard exhaustiveRetryTask == nil, let video = currentVideo else { return }
                playerLog.notice("[stall] \(source): stuck online after \(nudges) nudges — reloading stream")
                let error = NSError(
                    domain: "iPocketTube.PlaybackStall", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Stall without data on a live network — stream reload"]
                )
                exhaustiveRetryTask = Task { await self.exhaustiveRetry(video: video, originalError: error) }
                return
            }
        }
    }

    /// End of the furthest loaded range, in seconds.
    static func bufferedEnd(of item: AVPlayerItem) -> Double {
        item.loadedTimeRanges
            .map { CMTimeGetSeconds(CMTimeRangeGetEnd($0.timeRangeValue)) }
            .filter(\.isFinite)
            .max() ?? 0
    }
}
