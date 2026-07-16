import Foundation

/// One deterministic source of truth for Downloads ordering. The current
/// recoverable Now Playing item is pinned without mutating its history dates.
public enum DownloadHistorySortPolicy {
    public static func sorted(
        _ entries: [DownloadedVideo],
        currentItemID: String?
    ) -> [DownloadedVideo] {
        entries.sorted { lhs, rhs in
            let lhsIsCurrent = lhs.id == currentItemID
            let rhsIsCurrent = rhs.id == currentItemID
            if lhsIsCurrent != rhsIsCurrent { return lhsIsCurrent }

            switch (lhs.lastPlayedAt, rhs.lastPlayedAt) {
            case let (lhsDate?, rhsDate?) where lhsDate != rhsDate:
                return lhsDate > rhsDate
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                break
            }

            switch (lhs.downloadedAt, rhs.downloadedAt) {
            case let (lhsDate?, rhsDate?) where lhsDate != rhsDate:
                return lhsDate > rhsDate
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                return lhs.id < rhs.id
            }
        }
    }
}

public enum DownloadTimestampBucket: Equatable, Sendable {
    case today
    case yesterday
    case earlier
    case unknown
}

public enum DownloadTimestampPolicy {
    public static func bucket(
        for date: Date?,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> DownloadTimestampBucket {
        guard let date else { return .unknown }
        if calendar.isDate(date, inSameDayAs: now) { return .today }
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: now) else {
            return .earlier
        }
        return calendar.isDate(date, inSameDayAs: yesterday) ? .yesterday : .earlier
    }
}
