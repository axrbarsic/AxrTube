import AVFoundation

extension AVPlayerItem {
    /// An `AsyncStream` that emits the item's `status` on each KVO change.
    var statusStream: AsyncStream<AVPlayerItem.Status> {
        AsyncStream { continuation in
            let observer = observe(\.status, options: [.initial, .new]) { item, _ in
                continuation.yield(item.status)
                if item.status == .readyToPlay || item.status == .failed {
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in observer.invalidate() }
        }
    }

    /// An `AsyncStream` that emits the first finite, positive `duration` value observed
    /// via KVO on `AVPlayerItem.duration`, then finishes. For some HLS streams the
    /// duration is `.invalid` at `.readyToPlay` and only becomes valid after the first
    /// playlist segments are loaded — this stream handles that deferred case.
    var firstValidDurationStream: AsyncStream<TimeInterval> {
        AsyncStream { continuation in
            let observer = observe(\.duration, options: [.initial, .new]) { item, _ in
                let seconds = item.duration.seconds
                if seconds.isFinite && seconds > 0 {
                    continuation.yield(seconds)
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in observer.invalidate() }
        }
    }
}
