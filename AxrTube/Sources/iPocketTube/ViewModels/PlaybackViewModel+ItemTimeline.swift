import AVFoundation

extension PlaybackViewModel {
    /// Duration belongs to the installed AVPlayerItem, not a particular resolver,
    /// screen or ready-to-play branch. This also covers local files and quality swaps.
    func setupItemDurationObserver() {
        durationItemObservation = player.observe(\.currentItem, options: [.initial, .new]) { [weak self] player, _ in
            let item = player.currentItem
            Task { @MainActor [weak self, weak item] in
                guard let self, self.player.currentItem === item else { return }
                self.durationObserverTask?.cancel()
                self.durationObserverTask = nil
                guard let item else {
                    self.duration = 0
                    return
                }
                self.durationObserverTask = Task { @MainActor [weak self, weak item] in
                    guard let item else { return }
                    for await seconds in item.firstValidDurationStream {
                        guard !Task.isCancelled, let self else { return }
                        self.publishItemDuration(seconds, from: item)
                    }
                }
            }
        }
    }

    func publishItemDuration(_ seconds: TimeInterval, from item: AVPlayerItem) {
        guard player.currentItem === item, seconds.isFinite, seconds > 0 else { return }
        duration = seconds
        #if canImport(UIKit)
        if parkedVideoId == nil { updateNowPlayingInfo() }
        #endif
    }
}
