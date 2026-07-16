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

    @Test("Localized display labels never drive ordering")
    func localizedLabelIsIgnored() {
        let first = video("first", date: nil, label: "10 years ago")
        let second = video("second", date: nil, label: "today")

        #expect(VideoPublicationSortPolicy.sorted([first, second], for: .search).map(\.id) == ["first", "second"])
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

        #expect(VideoPublicationSortPolicy.sorted(input, for: .history).map(\.id) == input.map(\.id))
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

    @Test("Failed enrichment is negatively cached and remains unknown")
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
