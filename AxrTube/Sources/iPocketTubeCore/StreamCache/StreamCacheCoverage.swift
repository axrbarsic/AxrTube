import Foundation

/// What part of the current video is on disk, for the progress bar.
public struct StreamCacheProgress: Equatable, Sendable {
    /// Cached time ranges in seconds, sorted and merged.
    public var ranges: [ClosedRange<Double>]
    public var duration: Double
    public var isComplete: Bool

    public init(ranges: [ClosedRange<Double>], duration: Double, isComplete: Bool) {
        self.ranges = ranges
        self.duration = duration
        self.isComplete = isComplete
    }
}

public enum StreamCacheCoverage {
    /// Time ranges covered by the `done` segments, adjacent ones merged.
    public static func ranges(starts: [Double], durations: [Double], done: Set<Int>) -> [ClosedRange<Double>] {
        var result: [ClosedRange<Double>] = []
        for index in done.sorted() where index < starts.count && index < durations.count {
            let start = starts[index], end = starts[index] + durations[index]
            if let last = result.last, start <= last.upperBound + 0.01 {
                result[result.count - 1] = last.lowerBound...max(last.upperBound, end)
            } else {
                result.append(start...end)
            }
        }
        return result
    }

    /// Ranges present in both lists (video and its separate audio).
    public static func intersect(_ a: [ClosedRange<Double>], _ b: [ClosedRange<Double>]) -> [ClosedRange<Double>] {
        var result: [ClosedRange<Double>] = []
        var i = 0, j = 0
        while i < a.count, j < b.count {
            let low = max(a[i].lowerBound, b[j].lowerBound)
            let high = min(a[i].upperBound, b[j].upperBound)
            if low < high { result.append(low...high) }
            if a[i].upperBound < b[j].upperBound { i += 1 } else { j += 1 }
        }
        return result
    }
}
