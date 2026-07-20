import Foundation
import Testing
@testable import iPocketTubeCore

@Suite("iPocketTube publication date policy")
struct VideoPublicationSortPolicyTests {
    private func video(_ id: String, date: Date?, label: String? = nil) -> Video {
        Video(
            id: id,
            title: id,
            channelTitle: "Channel",
            publishedAt: date,
            publishedTimeText: label
        )
    }

    @Test("Production route table keeps playlist queue and Downloads exceptions explicit")
    func routeTable() {
        #expect(Set(VideoListRoute.allCases) == Set([
            .search, .home, .recommended, .subscriptions, .history, .channel, .rss,
            .playlist, .queue, .downloads,
        ]))
        #expect(!VideoListRoute.playlist.usesNewestFirstPublicationOrder)
        #expect(!VideoListRoute.queue.usesNewestFirstPublicationOrder)
        #expect(!VideoListRoute.downloads.usesNewestFirstPublicationOrder)
        #expect(!VideoListRoute.history.usesNewestFirstPublicationOrder)
    }

    @Test("Exact UTC dates sort newest first and unknown dates stay last")
    func exactUTCSortAndUnknownLast() {
        let old = Date(timeIntervalSince1970: 1_700_000_000)
        let new = Date(timeIntervalSince1970: 1_800_000_000)
        let input = [video("unknown", date: nil), video("old", date: old), video("new", date: new)]

        #expect(VideoPublicationSortPolicy.sorted(input, for: .home).map(\.id) == ["new", "old", "unknown"])
    }

    @Test("Player microformat calendar day is normalized to UTC")
    func microformatUTCParsing() throws {
        let date = try #require(YouTubePublicationDateParser.parseUTCDate("2026-07-15"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let components = calendar.dateComponents([.year, .month, .day, .hour], from: date)
        #expect(components.year == 2026)
        #expect(components.month == 7)
        #expect(components.day == 15)
        #expect(components.hour == 0)
    }

    @Test("Official/player ISO timestamp preserves the exact instant")
    func exactISOTimestampParsing() throws {
        let date = try #require(YouTubePublicationDateParser.parseUTCDate("2026-07-15T09:00:37-07:00"))
        #expect(date == ISO8601DateFormatter().date(from: "2026-07-15T16:00:37Z"))
    }

    @Test("Watch HTML player and schema metadata parse ISO publication dates")
    func watchHTMLParsing() throws {
        let player = #"<script>{"microformat":{"playerMicroformatRenderer":{"publishDate":"2026-07-15"}}}</script>"#
        let schema = #"<meta itemprop="datePublished" content="2025-06-14T11:12:13Z">"#

        #expect(YouTubePublicationDateParser.parseWatchHTML(player) != nil)
        #expect(YouTubePublicationDateParser.parseWatchHTML(schema) == ISO8601DateFormatter().date(from: "2025-06-14T11:12:13Z"))
    }

    @Test("English and Russian relative dates sort newest first; unknown stays last")
    func relativeChronologyAndUnknownLast() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let input = [
            video("unknown", date: nil),
            video("years", date: nil, label: "2 года назад"),
            video("hours", date: nil, label: "3 hours ago"),
            video("today", date: nil, label: "сегодня"),
        ]

        #expect(VideoPublicationSortPolicy.sorted(input, for: .search, now: now).map(\.id) == ["today", "hours", "years", "unknown"])
    }

    @Test("Equal dates and unknown blocks retain stable source order")
    func stableTies() {
        let date = Date(timeIntervalSince1970: 1_750_000_000)
        let input = [
            video("known-b", date: date),
            video("known-a", date: date),
            video("unknown-b", date: nil),
            video("unknown-a", date: nil),
        ]

        #expect(VideoPublicationSortPolicy.sorted(input, for: .home).map(\.id) == input.map(\.id))
    }

    @Test("Continuation merge inserts a newer result without duplicates")
    func paginationMerge() {
        let existing = [
            video("middle", date: Date(timeIntervalSince1970: 200)),
            video("old", date: Date(timeIntervalSince1970: 100)),
        ]
        let page = [
            video("new", date: Date(timeIntervalSince1970: 300)),
            video("old", date: Date(timeIntervalSince1970: 100)),
        ]

        #expect(VideoPublicationSortPolicy.merging(existing: existing, page: page, for: .channel).map(\.id) == ["new", "middle", "old"])
    }

    @Test("Playlist and queue preserve explicit order")
    func explicitOrderException() {
        let input = [
            video("manual-first", date: Date(timeIntervalSince1970: 100)),
            video("manual-second", date: Date(timeIntervalSince1970: 300)),
        ]

        #expect(VideoPublicationSortPolicy.sorted(input, for: .playlist).map(\.id) == input.map(\.id))
        #expect(VideoPublicationSortPolicy.sorted(input, for: .queue).map(\.id) == input.map(\.id))
    }

    @Test("History preserves watch chronology while publication metadata remains intact")
    func historyPreservesWatchChronology() {
        let input = [
            video("watched-first", date: Date(timeIntervalSince1970: 100), label: "2 года назад"),
            video("watched-second", date: Date(timeIntervalSince1970: 300), label: "сегодня"),
        ]

        let result = VideoPublicationSortPolicy.sorted(input, for: .history)
        #expect(result.map(\.id) == input.map(\.id))
        #expect(result.map(\.publishedTimeText) == input.map(\.publishedTimeText))
    }

    @Test("Playlist summaries do not claim a video publication date")
    func playlistSummaryPresentation() {
        let summary = Video(id: "PL123", title: "Playlist", channelTitle: "", playlistId: "PL123")
        let item = Video(id: "video", title: "Video", channelTitle: "", playlistId: "PL123")

        #expect(!VideoPublicationPresentationPolicy.showsPublicationDate(for: summary))
        #expect(VideoPublicationPresentationPolicy.showsPublicationDate(for: item))
    }

    @Test("Enrichment succeeds once, deduplicates IDs, and reuses TTL cache")
    func enrichmentSuccessDedupAndCache() async {
        let counter = PublicationResolverCounter(result: Date(timeIntervalSince1970: 400))
        let enricher = VideoPublicationDateEnricher(successTTL: 3_600, failureTTL: 60, maxConcurrentRequests: 2)
        let input = [video("same", date: nil), video("same", date: nil)]

        let first = await enricher.enrich(input) { id in await counter.resolve(id) }
        let second = await enricher.enrich(input) { id in await counter.resolve(id) }

        #expect(first.allSatisfy { $0.publishedAt != nil })
        #expect(second.allSatisfy { $0.publishedAt != nil })
        #expect(await counter.callCount == 1)
    }

    @Test("Duplicate IDs across Home shelves build one metadata entry without trapping")
    func duplicateHomeShelfMetadataIsSafe() {
        let exactDate = Date(timeIntervalSince1970: 600)
        let unresolved = video("shared-video", date: nil)
        let exact = video("shared-video", date: exactDate)

        let metadata = VideoPublicationSortPolicy.metadataByVideoID([unresolved, exact, unresolved])

        #expect(metadata.count == 1)
        #expect(metadata["shared-video"]?.publishedAt == exactDate)
    }

    @Test("Duplicate metadata prefers exact then relative then unknown")
    func duplicateMetadataQuality() {
        let unknown = video("same", date: nil)
        let relative = video("same", date: nil, label: "3 days ago")
        let exactDate = Date(timeIntervalSince1970: 700)
        let exact = video("same", date: exactDate)

        let relativeWinner = VideoPublicationSortPolicy.metadataByVideoID([unknown, relative])
        #expect(relativeWinner["same"]?.publishedTimeText == "3 days ago")

        let exactWinner = VideoPublicationSortPolicy.metadataByVideoID([relative, exact, unknown])
        #expect(exactWinner["same"]?.publishedAt == exactDate)
        #expect(exactWinner["same"]?.publishedTimeText == "3 days ago")
    }

    @Test("Failed exact enrichment cannot erase a renderer-relative label")
    func relativeSurvivesFailedEnrichment() async {
        let enricher = VideoPublicationDateEnricher(successTTL: 60, failureTTL: 60, maxConcurrentRequests: 1)
        let input = [video("relative", date: nil, label: "3 days ago")]

        let enriched = await enricher.enrich(input) { _ in nil }
        let merged = VideoPublicationSortPolicy.mergingPublicationMetadata(base: input[0], candidate: enriched[0])

        #expect(merged.publishedTimeText == "3 days ago")
        #expect(merged.publicationDateStatus == .unavailable)
        #expect(VideoPublicationFormatter.string(
            for: merged,
            locale: Locale(identifier: "ru_RU")
        ) != "Дата неизвестна")
    }

    @Test("A late exact enrichment atomically re-sorts a secondary route")
    func lateEnrichmentResortsChannel() async {
        let enricher = VideoPublicationDateEnricher(successTTL: 60, failureTTL: 60, maxConcurrentRequests: 2)
        let input = [video("old", date: nil), video("new", date: nil)]
        let dates = [
            "old": Date(timeIntervalSince1970: 100),
            "new": Date(timeIntervalSince1970: 300),
        ]

        let enriched = await enricher.enrich(input) { dates[$0] }
        #expect(VideoPublicationSortPolicy.sorted(enriched, for: .channel).map(\.id) == ["new", "old"])
    }

    @Test("Channel route uses the same publication merge and display fallback")
    func secondaryRouteUsesSharedPolicy() {
        let unknown = video("same", date: nil)
        let relative = video("same", date: nil, label: "вчера")
        var failed = relative
        failed.publicationDateStatus = .unavailable

        let merged = VideoPublicationSortPolicy.merging(
            existing: [unknown],
            page: [failed],
            for: .channel
        )

        #expect(merged.count == 1)
        #expect(merged[0].publishedTimeText == "вчера")
        #expect(VideoPublicationFormatter.string(
            for: merged[0],
            locale: Locale(identifier: "ru_RU")
        ) == "вчера")
    }

    @Test("Failed exact enrichment is negatively cached")
    func enrichmentFailureCache() async {
        let counter = PublicationResolverCounter(result: nil)
        let enricher = VideoPublicationDateEnricher(successTTL: 3_600, failureTTL: 60, maxConcurrentRequests: 2)
        let input = [video("missing", date: nil)]

        let first = await enricher.enrich(input) { id in await counter.resolve(id) }
        let second = await enricher.enrich(input) { id in await counter.resolve(id) }

        #expect(first[0].publishedAt == nil)
        #expect(second[0].publishedAt == nil)
        #expect(first[0].publicationDateStatus == .unavailable)
        #expect(second[0].publicationDateStatus == .unavailable)
        #expect(await counter.callCount == 1)
    }

    @Test("TTL expiry permits a fresh metadata resolve")
    func enrichmentTTLExpiry() async {
        let counter = PublicationResolverCounter(result: Date(timeIntervalSince1970: 500))
        let enricher = VideoPublicationDateEnricher(successTTL: 10, failureTTL: 5, maxConcurrentRequests: 1)
        let input = [video("ttl", date: nil)]
        let start = Date(timeIntervalSince1970: 1_000)

        _ = await enricher.enrich(input, now: start) { id in await counter.resolve(id) }
        _ = await enricher.enrich(input, now: start.addingTimeInterval(11)) { id in await counter.resolve(id) }

        #expect(await counter.callCount == 2)
    }
}

private actor PublicationResolverCounter {
    private(set) var callCount = 0
    private let result: Date?

    init(result: Date?) { self.result = result }

    func resolve(_ id: String) -> Date? {
        callCount += 1
        return result
    }
}
