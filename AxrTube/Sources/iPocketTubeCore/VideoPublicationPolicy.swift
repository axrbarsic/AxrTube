import Foundation

public enum YouTubePublicationDateParser {
    /// Player/Data API metadata can expose either an ISO-8601 instant or a
    /// locale-independent `yyyy-MM-dd` calendar day. Preserve a real instant;
    /// normalize a day-only value to midnight UTC.
    public static func parseUTCDate(_ raw: String) -> Date? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: value) { return date }
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: value) { return date }

        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: value)
    }

    /// Last-resort extraction from the public watch page. YouTube exposes the
    /// same locale-independent publication values in player microformat JSON
    /// and, for some renderer variants, in schema.org meta tags.
    public static func parseWatchHTML(_ html: String) -> Date? {
        let patterns = [
            #"\"publishDate\"\s*:\s*\"([^\"]+)\""#,
            #"\"uploadDate\"\s*:\s*\"([^\"]+)\""#,
            #"itemprop=[\"'](?:datePublished|uploadDate)[\"'][^>]*content=[\"']([^\"']+)[\"']"#,
            #"content=[\"']([^\"']+)[\"'][^>]*itemprop=[\"'](?:datePublished|uploadDate)[\"']"#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let match = regex.firstMatch(
                    in: html,
                    range: NSRange(html.startIndex..., in: html)
                  ),
                  let range = Range(match.range(at: 1), in: html)
            else { continue }
            if let date = parseUTCDate(String(html[range])) { return date }
        }
        return nil
    }
}

/// Converts YouTube's coarse relative labels to a typed age used only for
/// chronology. The original text remains the display source; no approximate
/// age is ever presented as an invented exact calendar date.
public enum YouTubePublicationRelativeParser {
    public static func approximateAge(_ raw: String) -> TimeInterval? {
        let value = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "ё", with: "е")
        guard !value.isEmpty else { return nil }
        if value == "today" || value == "сегодня" { return 0 }
        if value == "yesterday" || value == "вчера" { return 24 * 60 * 60 }

        let pattern = #"(\d+)\s+([\p{L}]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              let numberRange = Range(match.range(at: 1), in: value),
              let unitRange = Range(match.range(at: 2), in: value),
              let amount = Double(value[numberRange])
        else { return nil }

        let unit = String(value[unitRange])
        let unitSeconds: TimeInterval
        switch unit {
        case "second", "seconds", "секунда", "секунды", "секунд", "секунду":
            unitSeconds = 1
        case "minute", "minutes", "минута", "минуты", "минут", "минуту":
            unitSeconds = 60
        case "hour", "hours", "час", "часа", "часов":
            unitSeconds = 60 * 60
        case "day", "days", "день", "дня", "дней":
            unitSeconds = 24 * 60 * 60
        case "week", "weeks", "неделя", "недели", "недель", "неделю":
            unitSeconds = 7 * 24 * 60 * 60
        case "month", "months", "месяц", "месяца", "месяцев":
            unitSeconds = 30 * 24 * 60 * 60
        case "year", "years", "год", "года", "лет":
            unitSeconds = 365 * 24 * 60 * 60
        default:
            return nil
        }
        return amount * unitSeconds
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
        case .search, .home, .recommended, .subscriptions, .channel, .rss:
            true
        case .history, .playlist, .queue, .downloads:
            false
        }
    }
}

/// One stable, typed publication-date ordering policy shared by every feed.
/// Exact dates are preferred; parseable relative metadata contributes only a
/// coarse typed age. Localized labels are never compared lexicographically.
public enum VideoPublicationSortPolicy {
    private enum MetadataQuality: Int {
        case unknown = 0
        case relative = 1
        case exact = 2
    }

    private static func normalizedRelativeLabel(_ video: Video) -> String? {
        guard let label = video.publishedTimeText?.trimmingCharacters(in: .whitespacesAndNewlines),
              !label.isEmpty else { return nil }
        return label
    }

    private static func metadataQuality(_ video: Video) -> MetadataQuality {
        if video.publishedAt != nil { return .exact }
        if normalizedRelativeLabel(video) != nil { return .relative }
        return .unknown
    }

    /// Merges publication metadata without ever replacing a more trustworthy
    /// value with a failed/empty enrichment result. Renderer-relative text is
    /// intentionally kept when the exact player lookup is unavailable.
    public static func mergingPublicationMetadata(base: Video, candidate: Video) -> Video {
        var result = base

        if result.publishedAt == nil, let exact = candidate.publishedAt {
            result.publishedAt = exact
            result.publicationDateStatus = .exact
        }
        if normalizedRelativeLabel(result) == nil,
           let relative = normalizedRelativeLabel(candidate) {
            result.publishedTimeText = relative
        }

        if result.publishedAt != nil {
            result.publicationDateStatus = .exact
        } else if result.publicationDateStatus == nil,
                  candidate.publicationDateStatus == .unavailable {
            // This status records only that exact lookup was exhausted. It must
            // not suppress an independently valid renderer-relative label.
            result.publicationDateStatus = .unavailable
        }
        return result
    }

    /// Builds a stable lookup for feed snapshots where the same YouTube video
    /// can legitimately appear in multiple shelves. Prefer the copy carrying
    /// an exact publication date, but never trap on a duplicate ID.
    public static func metadataByVideoID(_ videos: [Video]) -> [String: Video] {
        Dictionary(videos.map { ($0.id, $0) }, uniquingKeysWith: { existing, candidate in
            if metadataQuality(candidate).rawValue > metadataQuality(existing).rawValue {
                return mergingPublicationMetadata(base: candidate, candidate: existing)
            }
            return mergingPublicationMetadata(base: existing, candidate: candidate)
        })
    }

    public static func sorted(
        _ videos: [Video],
        for route: VideoListRoute,
        now: Date = Date()
    ) -> [Video] {
        guard route.usesNewestFirstPublicationOrder else { return videos }

        func chronologyDate(_ video: Video) -> Date? {
            if let exact = video.publishedAt { return exact }
            guard let relative = normalizedRelativeLabel(video),
                  let age = YouTubePublicationRelativeParser.approximateAge(relative)
            else { return nil }
            return now.addingTimeInterval(-age)
        }

        return videos.enumerated().sorted { lhs, rhs in
            switch (chronologyDate(lhs.element), chronologyDate(rhs.element)) {
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
        var indices: [String: Int] = [:]
        var merged: [Video] = []
        for video in existing + page {
            if let index = indices[video.id] {
                merged[index] = mergingPublicationMetadata(base: merged[index], candidate: video)
            } else {
                indices[video.id] = merged.count
                merged.append(video)
            }
        }
        return sorted(merged, for: route)
    }
}

/// Playlist catalogue rows reuse the card geometry but describe a collection,
/// not a YouTube video. They must not claim a missing video publication date.
public enum VideoPublicationPresentationPolicy {
    public static func showsPublicationDate(for video: Video) -> Bool {
        video.playlistId == nil || video.playlistId != video.id
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
    /// Cap so a long-lived app process cannot grow the dictionary without bound
    /// (one entry per unique video ID, never evicted otherwise).
    private static let maxCacheEntries = 2_000
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

    /// Removes expired entries and, when the cap is exceeded, the oldest
    /// surviving entries. Bounded work: only runs after a fresh insertion.
    private func evictExpired(now: Date) {
        if cache.count < Self.maxCacheEntries {
            cache = cache.filter { $0.value.expiresAt > now }
            return
        }
        let expiredKeys = cache.filter { $0.value.expiresAt <= now }.map(\.key)
        for key in expiredKeys { cache.removeValue(forKey: key) }
        while cache.count >= Self.maxCacheEntries, let oldest = cache.min(by: { $0.value.expiresAt < $1.value.expiresAt }) {
            cache.removeValue(forKey: oldest.key)
        }
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
        evictExpired(now: now)
        return date
    }
}
