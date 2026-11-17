import Foundation

/// Which segments to download next: playhead-first, onward to the end of
/// the video, then whatever a seek skipped — never twice.
public enum SegmentPrefetchPlanner {
    /// - Parameters:
    ///   - count: segments in the playlist.
    ///   - cursor: index the player asked for most recently.
    ///   - done: indices already on disk.
    ///   - busy: indices being downloaded.
    ///   - slots: free download slots.
    public static func next(count: Int, cursor: Int, done: Set<Int>, busy: Set<Int>, slots: Int) -> [Int] {
        guard slots > 0, count > 0 else { return [] }
        var picked: [Int] = []
        var i = max(0, min(cursor, count - 1))
        while i < count, picked.count < slots {
            if !done.contains(i), !busy.contains(i) { picked.append(i) }
            i += 1
        }
        // Everything ahead is done: fill what a seek skipped, from the start.
        i = 0
        while i < count, picked.count < slots {
            if !done.contains(i), !busy.contains(i), !picked.contains(i) { picked.append(i) }
            i += 1
        }
        return picked
    }
}

/// Smoothed download speed, persisted so the next video starts with a
/// sensible quality on the same (weak) connection.
public struct ThroughputEstimate: Codable, Equatable, Sendable {
    public private(set) var bitsPerSecond: Double?
    public private(set) var updatedAt: Date?

    public init(bitsPerSecond: Double? = nil, updatedAt: Date? = nil) {
        self.bitsPerSecond = bitsPerSecond
        self.updatedAt = updatedAt
    }

    /// Ignores tiny transfers whose timing is dominated by latency.
    public mutating func record(bytes: Int, seconds: TimeInterval, now: Date = Date()) {
        guard bytes >= 64 * 1024, seconds > 0.05 else { return }
        let sample = Double(bytes) * 8 / seconds
        bitsPerSecond = bitsPerSecond.map { $0 * 0.7 + sample * 0.3 } ?? sample
        updatedAt = now
    }

    /// Bandwidth the chosen variant may need: 70 % of measured throughput,
    /// so downloading outruns playback. Nil when unknown or older than a day.
    public func variantBudget(parallelConnections: Int, now: Date = Date()) -> Int? {
        guard let bps = bitsPerSecond, let at = updatedAt, now.timeIntervalSince(at) < 86_400 else { return nil }
        return Int(bps * Double(max(parallelConnections, 1)) * 0.7)
    }
}

/// Tunables of the caching proxy.
public enum StreamCachePolicy {
    /// Parallel segment downloads ahead of the playhead. Several connections
    /// survive packet loss and per-connection throttling better than one.
    public static let prefetchConnections = 3
    /// Quality cap when the user picked Auto and the network is unknown.
    public static let unknownNetworkMaxHeight = 720
    public static let autoMaxHeight = 1080
    /// Retry delay for a failed segment while the network is up.
    public static func retryDelay(attempt: Int) -> TimeInterval {
        min(30, pow(2, Double(min(attempt, 5))))
    }

    /// Cache limit: the user's ceiling (2 GB by default), but never leave the
    /// phone with less than ~3 GB free.
    public static func limitBytes(availableCapacity: Int64?, current: Int64,
                                  ceiling: Int64 = 2 * 1024 * 1024 * 1024) -> Int64 {
        guard let available = availableCapacity else { return ceiling }
        let reserve: Int64 = 3 * 1024 * 1024 * 1024
        let allowed = current + available - reserve
        return max(200 * 1024 * 1024, min(ceiling, allowed))
    }
}
