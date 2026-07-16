import Foundation

public enum YouTubePublicationDateParser {
    /// InnerTube player microformat exposes a locale-independent `yyyy-MM-dd`
    /// calendar day. Normalize it to midnight UTC.
    public static func parseUTCDate(_ raw: String) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: raw)
    }
}

/// Production routes that render collections of videos. Explicitly ordered
/// playlists and queues preserve their server/user order; Downloads has its own
/// local-history contract and never uses YouTube publication time.
public enum VideoListRoute: String, Sendable, CaseIterable {
    case search
    case home
    case recommended
    case subscriptions
    case history
    case channel
    case rss
    case playlist
    case queue
    case downloads

    public var usesNewestFirstPublicationOrder: Bool {
        switch self {
        case .search, .home, .recommended, .subscriptions, .history, .channel, .rss:
            true
        case .playlist, .queue, .downloads:
            false
        }
    }
}

/// One stable, typed publication-date ordering policy shared by every feed.
/// Display strings such as "today" or "Дата неизвестна" never participate.
public enum VideoPublicationSortPolicy {
    public static func sorted(_ videos: [Video], for route: VideoListRoute) -> [Video] {
        guard route.usesNewestFirstPublicationOrder else { return videos }

        return videos.enumerated().sorted { lhs, rhs in
            switch (lhs.element.publishedAt, rhs.element.publishedAt) {
            case let (left?, right?) where left != right:
                return left > right
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                // Preserve source order for equal/unknown dates. The final ID
                // comparison makes malformed duplicate-position inputs deterministic.
                if lhs.offset != rhs.offset { return lhs.offset < rhs.offset }
                return lhs.element.id < rhs.element.id
            }
        }.map(\.element)
    }

    /// Deduplicates a continuation page, then re-applies the same stable policy
    /// to the complete snapshot so newly discovered newer items land correctly.
    public static func merging(
        existing: [Video],
        page: [Video],
        for route: VideoListRoute
    ) -> [Video] {
        var seen = Set<String>()
        let merged = (existing + page).filter { seen.insert($0.id).inserted }
        return sorted(merged, for: route)
    }
}

/// Deduplicated, bounded publication-date enrichment. Results are committed to
/// a returned batch only after all selected requests finish, preventing a feed
/// from jumping once per metadata response.
public actor VideoPublicationDateEnricher {
    public static let shared = VideoPublicationDateEnricher()

    private struct CacheEntry: Sendable {
        let date: Date?
        let expiresAt: Date
    }

    private let successTTL: TimeInterval
    private let failureTTL: TimeInterval
    private let maxConcurrentRequests: Int
    private var cache: [String: CacheEntry] = [:]
    private var inFlight: [String: Task<Date?, Never>] = [:]

    public init(
        successTTL: TimeInterval = 7 * 24 * 60 * 60,
        failureTTL: TimeInterval = 60 * 60,
        maxConcurrentRequests: Int = 4
    ) {
        self.successTTL = successTTL
        self.failureTTL = failureTTL
        self.maxConcurrentRequests = max(1, maxConcurrentRequests)
    }

    public func enrich(
        _ videos: [Video],
        now: Date = Date(),
        resolver: @escaping @Sendable (String) async -> Date?
    ) async -> [Video] {
        let missingIDs = Array(Set(videos.compactMap { $0.publishedAt == nil ? $0.id : nil })).sorted()
        guard !missingIDs.isEmpty else { return videos }

        var resolved: [String: Date] = [:]
        var attempted = Set<String>()
        for start in stride(from: 0, to: missingIDs.count, by: maxConcurrentRequests) {
            guard !Task.isCancelled else { break }
            let end = min(start + maxConcurrentRequests, missingIDs.count)
            let batch = Array(missingIDs[start..<end])
            await withTaskGroup(of: (String, Date?).self) { group in
                for id in batch {
                    group.addTask { [weak self] in
                        guard let self else { return (id, nil) }
                        return (id, await self.resolve(id: id, now: now, resolver: resolver))
                    }
                }
                for await (id, date) in group {
                    attempted.insert(id)
                    if let date { resolved[id] = date }
                }
            }
        }

        return videos.map { video in
            guard video.publishedAt == nil, attempted.contains(video.id) else { return video }
            var copy = video
            if let date = resolved[video.id] {
                copy.publishedAt = date
                copy.publicationDateStatus = .exact
            } else {
                copy.publicationDateStatus = .unavailable
            }
            return copy
        }
    }

    private func resolve(
        id: String,
        now: Date,
        resolver: @escaping @Sendable (String) async -> Date?
    ) async -> Date? {
        if let cached = cache[id], cached.expiresAt > now { return cached.date }
        if let task = inFlight[id] { return await task.value }

        let task = Task<Date?, Never> { await resolver(id) }
        inFlight[id] = task
        let date = await task.value
        inFlight[id] = nil
        cache[id] = CacheEntry(
            date: date,
            expiresAt: now.addingTimeInterval(date == nil ? failureTTL : successTTL)
        )
        return date
    }
}
