import Foundation
import Testing
@testable import iPocketTubeCore

// MARK: - MockInnerTubeAPI
//
// Synchronous, controllable stand-in for InnerTubeAPI.
// Set `*Result` properties to control what each fetch returns.
// All calls record themselves in `calls` for assertion.

@MainActor
final class MockInnerTubeAPI: InnerTubeAPIProtocol {

    // MARK: - Call recorder

    struct Call: Equatable {
        let method: String
        let args: [String]
    }
    var calls: [Call] = []

    // MARK: - Configurable return values

    var homeResult: VideoGroup = VideoGroup(title: "Home", videos: [])
    var homeRowsResult: [VideoGroup] = []
    var subscriptionsResult: VideoGroup = VideoGroup(title: "Subs", videos: [])
    var queuedHomeRows: [(result: [VideoGroup], delayMilliseconds: Int)] = []
    var queuedSubscriptions: [(result: VideoGroup, delayMilliseconds: Int)] = []
    var historyResult: VideoGroup = VideoGroup(title: "History", videos: [])
    var shortsResult: VideoGroup = VideoGroup(title: "Shorts", videos: [])
    var shortsMoreResult: VideoGroup = VideoGroup(title: "Shorts", videos: [])
    /// When set, overrides `shortsMoreResult` and is called for each
    /// `fetchShortsMore` invocation — lets tests vary the response per call
    /// (e.g. to simulate a multi-page continuation sequence).
    var shortsMoreHandler: ((String) -> VideoGroup)? = nil
    var musicResult: VideoGroup = VideoGroup(title: "Music", videos: [])
    var gamingResult: VideoGroup = VideoGroup(title: "Gaming", videos: [])
    var newsResult: VideoGroup = VideoGroup(title: "News", videos: [])
    var liveResult: VideoGroup = VideoGroup(title: "Live", videos: [])
    var sportsResult: VideoGroup = VideoGroup(title: "Sports", videos: [])
    var playlistsResult: [PlaylistInfo] = []
    var channelsResult: [Channel] = []
    var channelThumbnailResult: URL? = nil
    var channelResult: (channel: Channel, videos: VideoGroup) = (
        Channel(id: "ch1", title: "Channel"), VideoGroup(title: "Ch", videos: [])
    )
    var channelVideosResult: VideoGroup = VideoGroup(title: "ChVideos", videos: [])
    var searchResult: VideoGroup = VideoGroup(title: "Search", videos: [])
    var suggestionsResult: [String] = []
    var playlistVideosResult: VideoGroup = VideoGroup(title: "Playlist", videos: [])
    var errorToThrow: Error? = nil

    // MARK: - Protocol conformance

    func setAuthToken(_ token: String?) async {
        calls.append(Call(method: "setAuthToken", args: [token ?? "nil"]))
    }

    func setSAPISID(_ value: String?) async {
        calls.append(Call(method: "setSAPISID", args: [value ?? "nil"]))
    }

    func fetchHome(continuationToken: String?) async throws -> VideoGroup {
        calls.append(Call(method: "fetchHome", args: [continuationToken ?? "nil"]))
        if let e = errorToThrow { throw e }
        return homeResult
    }

    func fetchHomeRows(continuationToken: String?) async throws -> [VideoGroup] {
        calls.append(Call(method: "fetchHomeRows", args: [continuationToken ?? "nil"]))
        if let e = errorToThrow { throw e }
        if !queuedHomeRows.isEmpty {
            let queued = queuedHomeRows.removeFirst()
            if queued.delayMilliseconds > 0 {
                // Deliberately return the captured response even after cancellation;
                // this models a transport callback that arrives late.
                try? await Task.sleep(for: .milliseconds(queued.delayMilliseconds))
            }
            return queued.result
        }
        return homeRowsResult
    }

    func fetchSubscriptions(continuationToken: String?) async throws -> VideoGroup {
        calls.append(Call(method: "fetchSubscriptions", args: [continuationToken ?? "nil"]))
        if let e = errorToThrow { throw e }
        if !queuedSubscriptions.isEmpty {
            let queued = queuedSubscriptions.removeFirst()
            if queued.delayMilliseconds > 0 {
                try? await Task.sleep(for: .milliseconds(queued.delayMilliseconds))
            }
            return queued.result
        }
        return subscriptionsResult
    }

    func fetchHistory(continuationToken: String?) async throws -> VideoGroup {
        calls.append(Call(method: "fetchHistory", args: [continuationToken ?? "nil"]))
        if let e = errorToThrow { throw e }
        return historyResult
    }

    func fetchShorts() async throws -> VideoGroup {
        calls.append(Call(method: "fetchShorts", args: []))
        if let e = errorToThrow { throw e }
        return shortsResult
    }

    func fetchShortsMore(continuationToken: String) async throws -> VideoGroup {
        calls.append(Call(method: "fetchShortsMore", args: [continuationToken]))
        if let e = errorToThrow { throw e }
        if let handler = shortsMoreHandler { return handler(continuationToken) }
        return shortsMoreResult
    }

    func fetchMusic() async throws -> VideoGroup {
        calls.append(Call(method: "fetchMusic", args: []))
        if let e = errorToThrow { throw e }
        return musicResult
    }

    func fetchGaming() async throws -> VideoGroup {
        calls.append(Call(method: "fetchGaming", args: []))
        if let e = errorToThrow { throw e }
        return gamingResult
    }

    func fetchNews() async throws -> VideoGroup {
        calls.append(Call(method: "fetchNews", args: []))
        if let e = errorToThrow { throw e }
        return newsResult
    }

    func fetchLive() async throws -> VideoGroup {
        calls.append(Call(method: "fetchLive", args: []))
        if let e = errorToThrow { throw e }
        return liveResult
    }

    func fetchSports() async throws -> VideoGroup {
        calls.append(Call(method: "fetchSports", args: []))
        if let e = errorToThrow { throw e }
        return sportsResult
    }

    func fetchUserPlaylists() async throws -> [PlaylistInfo] {
        calls.append(Call(method: "fetchUserPlaylists", args: []))
        if let e = errorToThrow { throw e }
        return playlistsResult
    }

    func fetchSubscribedChannels() async throws -> [Channel] {
        calls.append(Call(method: "fetchSubscribedChannels", args: []))
        if let e = errorToThrow { throw e }
        return channelsResult
    }

    func fetchChannelThumbnailURL(channelId: String) async throws -> URL? {
        calls.append(Call(method: "fetchChannelThumbnailURL", args: [channelId]))
        return channelThumbnailResult
    }

    func fetchChannel(channelId: String) async throws -> (channel: Channel, videos: VideoGroup) {
        calls.append(Call(method: "fetchChannel", args: [channelId]))
        if let e = errorToThrow { throw e }
        return channelResult
    }

    func fetchChannelVideos(channelId: String, continuationToken: String?) async throws -> VideoGroup {
        calls.append(Call(method: "fetchChannelVideos", args: [channelId, continuationToken ?? "nil"]))
        if let e = errorToThrow { throw e }
        return channelVideosResult
    }

    func search(query: String, continuationToken: String?, filter: SearchFilter) async throws -> VideoGroup {
        calls.append(Call(method: "search", args: [query, continuationToken ?? "nil"]))
        if let e = errorToThrow { throw e }
        return searchResult
    }

    func fetchSearchSuggestions(query: String) async throws -> [String] {
        calls.append(Call(method: "fetchSearchSuggestions", args: [query]))
        if let e = errorToThrow { throw e }
        return suggestionsResult
    }

    func fetchPlaylistVideos(playlistId: String, continuationToken: String?) async throws -> VideoGroup {
        calls.append(Call(method: "fetchPlaylistVideos", args: [playlistId, continuationToken ?? "nil"]))
        if let e = errorToThrow { throw e }
        return playlistVideosResult
    }

    func addToWatchLater(videoId: String) async throws {
        calls.append(Call(method: "addToWatchLater", args: [videoId]))
        if let e = errorToThrow { throw e }
    }

    func removeFromWatchLater(videoId: String) async throws {
        calls.append(Call(method: "removeFromWatchLater", args: [videoId]))
        if let e = errorToThrow { throw e }
    }

    func sendFeedback(token: String) async throws {
        calls.append(Call(method: "sendFeedback", args: [token]))
        if let e = errorToThrow { throw e }
    }

    func sendFeedbackForVideo(videoId: String, iconType: String) async throws {
        calls.append(Call(method: "sendFeedbackForVideo", args: [videoId, iconType]))
        if let e = errorToThrow { throw e }
    }
}

// MARK: - Helpers

/// Yields control enough times so internal @MainActor Tasks spawned by
/// the ViewModel can complete against an immediately-returning mock API.
///
/// Without `until:`, this is a fixed delay (3 yields + 50ms) — fine when the
/// global executor is lightly loaded, but flaky under heavy parallel test
/// contention (confirmed: running the full `swift test` suite reliably
/// produced failures here that a `--filter ViewModelTests --no-parallel` run
/// never does — the underlying async work just hadn't completed yet when the
/// fixed delay elapsed). Pass `until:` for any assertion that depends on a
/// specific condition to poll for it directly instead of guessing a delay.
@MainActor
private func waitForTasks(timeout: TimeInterval = 2, until condition: (@MainActor () -> Bool)? = nil) async {
    guard let condition else {
        for _ in 0..<3 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(50))
        return
    }
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        await Task.yield()
        if condition() { return }
        try? await Task.sleep(for: .milliseconds(10))
    }
}

/// Waits for the background `shortsPreloadTask` (spawned at the end of
/// `load()`) to finish its multi-iteration loop. `waitForTasks()` is sized
/// for a single async fetch and returns long before the preload loop's
/// later iterations complete, so a left-running task can bleed mock call
/// counts into whichever test runs next. Polls until `homeShortsVideos`
/// stops growing for a few consecutive yields, or a timeout is reached.
@MainActor
private func waitForShortPreloadCompletion(_ vm: HomeViewModel) async {
    var lastCount = vm.homeShortsVideos.count
    var unchangedYields = 0
    let deadline = Date().addingTimeInterval(2)
    while Date() < deadline {
        await Task.yield()
        let newCount = vm.homeShortsVideos.count
        if newCount == lastCount {
            unchangedYields += 1
            if unchangedYields >= 3 { break }
        } else {
            unchangedYields = 0
        }
        lastCount = newCount
    }
}

private func makeVideo(_ id: String) -> Video {
    Video(id: id, title: "Video \(id)", channelTitle: "Channel")
}

/// Creates a `SearchViewModel` backed by a uniquely-suited `SearchHistoryStore`
/// instead of `.shared`, so tests don't read/write the same `UserDefaults`
/// search-history entries across the suite.
@MainActor
private func makeSearchViewModel(api: any InnerTubeAPIProtocol) -> SearchViewModel {
    SearchViewModel(api: api, historyStore: SearchHistoryStore(suiteName: "test-\(UUID().uuidString)"))
}

// MARK: - HomeViewModelTests

@Suite("HomeViewModel")
@MainActor
struct HomeViewModelTests {

    @Test("load() calls fetchHomeRows and fetchSubscriptions")
    func loadCallsBothFetches() async {
        let mock = MockInnerTubeAPI()
        mock.homeRowsResult = [VideoGroup(title: "Rec", videos: [makeVideo("vid_0000001")])]
        mock.subscriptionsResult = VideoGroup(title: "Subs", videos: [makeVideo("vid_0000002")])

        let vm = HomeViewModel(api: mock)
        defer { vm.cancel() }
        vm.load()
        await waitForTasks(until: {
            let methods = mock.calls.map(\.method)
            return methods.contains("fetchHomeRows") && methods.contains("fetchSubscriptions")
        })

        let methods = mock.calls.map(\.method)
        #expect(methods.contains("fetchHomeRows"))
        #expect(methods.contains("fetchSubscriptions"))
    }

    @Test("After load() completes, isRefreshing is false")
    func loadResetsIsRefreshing() async {
        let mock = MockInnerTubeAPI()
        mock.homeRowsResult = [VideoGroup(title: "Rec", videos: [makeVideo("vid_0000001")])]
        mock.subscriptionsResult = VideoGroup(title: "Subs", videos: [])

        let vm = HomeViewModel(api: mock)
        defer { vm.cancel() }
        vm.load()
        await waitForTasks()

        #expect(!vm.isRefreshing)
    }

    @Test("Home section is populated with videos from fetchHomeRows")
    func homeSectionPopulated() async {
        let mock = MockInnerTubeAPI()
        let video = makeVideo("vid_0000001")
        mock.homeRowsResult = [VideoGroup(title: "Rec", videos: [video])]
        mock.subscriptionsResult = VideoGroup(title: "Subs", videos: [])

        let vm = HomeViewModel(api: mock)
        defer { vm.cancel() }
        vm.load()
        await waitForTasks(until: {
            vm.sections.first { $0.section.type == .home }?.videos.isEmpty == false
        })

        let homeState = vm.sections.first { $0.section.type == .home }
        #expect(homeState?.videos.isEmpty == false)
    }

    @Test("mergedVideos interleaves rec and sub videos")
    func mergedVideosInterleaves() async {
        let mock = MockInnerTubeAPI()
        let recVideos = (0..<8).map { makeVideo("rec\($0)_AAAAAA") }
        let subVideos = (0..<4).map { makeVideo("sub\($0)_BBBBBB") }
        mock.homeRowsResult = [VideoGroup(title: "Rec", videos: recVideos)]
        mock.subscriptionsResult = VideoGroup(title: "Subs", videos: subVideos)

        let vm = HomeViewModel(api: mock)
        defer { vm.cancel() }
        vm.load()
        await waitForTasks()

        // mergedVideos inserts 1 sub every 4 recs; total should be > 8
        #expect(vm.mergedVideos.count > 8)
        // Subscription videos should appear in merged list
        let ids = Set(vm.mergedVideos.map(\.id))
        #expect(ids.contains("sub0_BBBBBB"))
    }

    @Test("mergedVideos with empty subs returns only recs")
    func mergedVideosEmptySubsReturnsRecs() async {
        let mock = MockInnerTubeAPI()
        mock.homeRowsResult = [VideoGroup(title: "Rec", videos: [makeVideo("vid_AAAAAAA")])]
        mock.subscriptionsResult = VideoGroup(title: "Subs", videos: [])

        let vm = HomeViewModel(api: mock)
        defer { vm.cancel() }
        vm.load()
        await waitForTasks()

        let recs = vm.sections.first { $0.section.type == .home }?.videos ?? []
        #expect(vm.mergedVideos == recs)
    }

    @Test("Refresh preserves the visible snapshot until one atomic commit")
    func refreshIsNonDestructive() async {
        let mock = MockInnerTubeAPI()
        mock.homeRowsResult = [VideoGroup(title: "Home", videos: [makeVideo("old-home")])]
        mock.subscriptionsResult = VideoGroup(title: "Subs", videos: [makeVideo("old-sub")])

        let vm = HomeViewModel(api: mock)
        defer { vm.cancel() }
        vm.load()
        await waitForTasks(until: { !vm.isRefreshing && vm.mergedVideos.count == 2 })
        let visibleBeforeRefresh = vm.mergedVideos.map(\.id)

        mock.queuedHomeRows = [(
            [VideoGroup(title: "Home", videos: [makeVideo("new-home"), makeVideo("old-home")])],
            120
        )]
        mock.queuedSubscriptions = [(
            VideoGroup(title: "Subs", videos: [makeVideo("old-sub")]),
            120
        )]

        let refreshTask = Task { await vm.refresh() }
        await waitForTasks(until: { vm.isRefreshing })

        #expect(vm.mergedVideos.map(\.id) == visibleBeforeRefresh)
        await refreshTask.value
        #expect(vm.mergedVideos.map(\.id) == ["new-home"] + visibleBeforeRefresh)
        #expect(!vm.isRefreshing)
    }

    @Test("Merged pagination appends one ordered deduplicated batch with one in-flight request")
    func mergedPaginationIsOrderedAndSingleFlight() async {
        let mock = MockInnerTubeAPI()
        mock.homeRowsResult = [VideoGroup(
            title: "Home",
            videos: [makeVideo("home-1")],
            nextPageToken: "home-page-2"
        )]
        mock.subscriptionsResult = VideoGroup(
            title: "Subs",
            videos: [makeVideo("sub-1")],
            nextPageToken: "subs-page-2"
        )

        let vm = HomeViewModel(api: mock)
        defer { vm.cancel() }
        vm.load()
        await waitForTasks(until: { !vm.isRefreshing && vm.mergedVideos.count == 2 })
        let initialIDs = vm.mergedVideos.map(\.id)

        mock.queuedHomeRows = [(
            [VideoGroup(
                title: "Home",
                videos: [makeVideo("home-1"), makeVideo("home-2"), makeVideo("home-2")]
            )],
            100
        )]
        mock.queuedSubscriptions = [(
            VideoGroup(
                title: "Subs",
                videos: [makeVideo("sub-1"), makeVideo("sub-2")]
            ),
            60
        )]

        vm.loadMoreMerged(triggeredBy: initialIDs.last)
        vm.loadMoreMerged(triggeredBy: initialIDs.last)
        await waitForTasks(until: { vm.isLoadingMoreMerged })
        #expect(vm.mergedVideos.map(\.id) == initialIDs)
        await waitForTasks(until: { !vm.isLoadingMoreMerged })

        #expect(vm.mergedVideos.map(\.id) == initialIDs + ["home-2", "sub-2"])
        #expect(Set(vm.mergedVideos.map(\.id)).count == vm.mergedVideos.count)
        #expect(mock.calls.filter { $0.method == "fetchHomeRows" && $0.args == ["home-page-2"] }.count == 1)
        #expect(mock.calls.filter { $0.method == "fetchSubscriptions" && $0.args == ["subs-page-2"] }.count == 1)
        #expect(!vm.hasMoreMerged)
    }

    @Test("Late continuation response cannot overwrite a newer refresh generation")
    func stalePaginationResponseIsIgnored() async {
        let mock = MockInnerTubeAPI()
        mock.homeRowsResult = [VideoGroup(
            title: "Home",
            videos: [makeVideo("current")],
            nextPageToken: "slow-page"
        )]
        mock.subscriptionsResult = VideoGroup(title: "Subs", videos: [])

        let vm = HomeViewModel(api: mock)
        defer { vm.cancel() }
        vm.load()
        await waitForTasks(until: { !vm.isRefreshing && vm.mergedVideos.map(\.id) == ["current"] })

        mock.queuedHomeRows = [
            ([VideoGroup(title: "Late", videos: [makeVideo("stale-page")])], 180),
            ([VideoGroup(title: "Fresh", videos: [makeVideo("fresh")])], 0),
        ]
        vm.loadMoreMerged(triggeredBy: "current")
        await waitForTasks(until: {
            mock.calls.contains { $0.method == "fetchHomeRows" && $0.args == ["slow-page"] }
        })
        await vm.refresh()
        await waitForTasks()

        #expect(vm.mergedVideos.map(\.id) == ["fresh"])
        #expect(!vm.mergedVideos.map(\.id).contains("stale-page"))
    }

    @Test("No-progress page exhausts its cursor and the visible sentinel cannot recurse")
    func noProgressPageStopsPaginationLoop() async {
        let mock = MockInnerTubeAPI()
        mock.homeRowsResult = [VideoGroup(
            title: "Home",
            videos: [makeVideo("sentinel")],
            nextPageToken: "repeat-token"
        )]
        mock.subscriptionsResult = VideoGroup(title: "Subs", videos: [])

        let vm = HomeViewModel(api: mock)
        defer { vm.cancel() }
        vm.load()
        await waitForTasks(until: { !vm.isRefreshing && vm.hasMoreMerged })

        mock.queuedHomeRows = [(
            [VideoGroup(
                title: "Repeated",
                videos: [makeVideo("sentinel")],
                nextPageToken: "repeat-token"
            )],
            0
        )]
        vm.loadMoreMerged(triggeredBy: "sentinel")
        await waitForTasks(until: { !vm.isLoadingMoreMerged && !vm.hasMoreMerged })
        vm.loadMoreMerged(triggeredBy: "sentinel")

        #expect(mock.calls.filter { $0.method == "fetchHomeRows" && $0.args == ["repeat-token"] }.count == 1)
        #expect(vm.mergedVideos.map(\.id) == ["sentinel"])
    }

    @Test("Dedicated Shorts paging never consumes the subscriptions continuation")
    func shortsPreloadDoesNotAdvanceSubscriptionsCursor() async {
        let mock = MockInnerTubeAPI()
        mock.homeRowsResult = []
        mock.subscriptionsResult = VideoGroup(
            title: "Subs",
            videos: [makeVideo("sub-current")],
            nextPageToken: "subs-next"
        )
        mock.shortsResult = VideoGroup(title: "Shorts", videos: [], nextPageToken: nil)

        let vm = HomeViewModel(api: mock)
        defer { vm.cancel() }
        vm.load()
        await waitForTasks(until: { !vm.isRefreshing })
        await waitForShortPreloadCompletion(vm)

        #expect(!mock.calls.contains { $0.method == "fetchSubscriptions" && $0.args == ["subs-next"] })
        #expect(!mock.calls.contains { $0.method == "search" })
        #expect(vm.hasMoreMerged)
    }

    @Test("Refresh removes entries absent from both supported Home sources")
    func refreshRemovesStaleSourceContamination() async {
        let mock = MockInnerTubeAPI()
        mock.homeRowsResult = [VideoGroup(
            title: "Home",
            videos: [makeVideo("youtube-card"), makeVideo("stale-fallback-movie")]
        )]
        mock.subscriptionsResult = VideoGroup(title: "Subs", videos: [])
        let vm = HomeViewModel(api: mock)
        defer { vm.cancel() }
        vm.load()
        await waitForTasks(until: { !vm.isRefreshing && vm.mergedVideos.count == 2 })

        mock.queuedHomeRows = [(
            [VideoGroup(title: "Home", videos: [makeVideo("youtube-card")])],
            0
        )]
        mock.queuedSubscriptions = [(VideoGroup(title: "Subs", videos: []), 0)]
        await vm.refresh()

        #expect(vm.mergedVideos.map(\.id) == ["youtube-card"])
    }

    @Test("homeRegularVideos excludes Shorts and homeShortsVideos contains only Shorts")
    func homePartitionsShorts() async {
        let mock = MockInnerTubeAPI()
        let regularVideo = makeVideo("reg0_AAAA")
        let shortVideo = Video(id: "srt0_BBBB", title: "A Short", channelTitle: "Channel", isShort: true)
        mock.homeRowsResult = [VideoGroup(title: "Rec", videos: [regularVideo, shortVideo])]
        mock.subscriptionsResult = VideoGroup(title: "Subs", videos: [])

        let vm = HomeViewModel(api: mock)
        defer { vm.cancel() }
        vm.load()
        await waitForTasks()

        #expect(vm.homeRegularVideos.allSatisfy { !$0.isShort })
        #expect(vm.homeShortsVideos.allSatisfy { $0.isShort })
        #expect(vm.homeRegularVideos.map(\.id).contains("reg0_AAAA"))
        #expect(vm.homeShortsVideos.map(\.id).contains("srt0_BBBB"))
    }

    @Test("loadMoreShortsIfNeeded auto-fetches next page when shorts < 6")
    func loadMoreShortsAutoFetchWhenBelowThreshold() async {
        let mock = MockInnerTubeAPI()
        // Initial page: 3 shorts with a continuation token
        let initialShorts = (0..<3).map { Video(id: "srt\($0)_AAAAA", title: "Short \($0)", channelTitle: "Ch", isShort: true) }
        mock.shortsResult = VideoGroup(title: "Shorts", videos: initialShorts, nextPageToken: "tok_page2")
        // Next page: 4 more shorts
        let moreShorts = (10..<14).map { Video(id: "srt\($0)_BBBBB", title: "Short \($0)", channelTitle: "Ch", isShort: true) }
        mock.shortsMoreResult = VideoGroup(title: "Shorts", videos: moreShorts, nextPageToken: nil)
        mock.homeRowsResult = []
        mock.subscriptionsResult = VideoGroup(title: "Subs", videos: [])

        let vm = HomeViewModel(api: mock)
        defer { vm.cancel() }
        vm.load()
        await waitForTasks()

        // fetchShortsMore must have been called
        #expect(mock.calls.contains(where: { $0.method == "fetchShortsMore" }))
        // shortsVideos should contain both pages (3 initial + 4 more = 7)
        #expect(vm.shortsVideos.count == 7)
    }

    @Test("loadMoreShortsIfNeeded skips auto-fetch when no continuation token")
    func loadMoreShortsSkipsWithNoToken() async {
        let mock = MockInnerTubeAPI()
        // Initial page: 2 shorts, no continuation token
        let initialShorts = (0..<2).map { Video(id: "srt\($0)_DDDDD", title: "Short \($0)", channelTitle: "Ch", isShort: true) }
        mock.shortsResult = VideoGroup(title: "Shorts", videos: initialShorts, nextPageToken: nil)
        mock.homeRowsResult = []
        mock.subscriptionsResult = VideoGroup(title: "Subs", videos: [])

        let vm = HomeViewModel(api: mock)
        defer { vm.cancel() }
        vm.load()
        await waitForTasks()

        // fetchShortsMore must NOT have been called
        #expect(!mock.calls.contains(where: { $0.method == "fetchShortsMore" }))
        #expect(vm.shortsVideos.count == 2)
    }

    @Test("loadMoreShortsIfNeeded deduplicates videos from next page")
    func loadMoreShortsDeduplicates() async {
        let mock = MockInnerTubeAPI()
        let initialShorts = (0..<3).map { Video(id: "srt\($0)_EEEEE", title: "Short \($0)", channelTitle: "Ch", isShort: true) }
        // Next page contains 2 new + 1 duplicate from first page
        let moreShorts = [
            Video(id: "srt0_EEEEE", title: "Dup", channelTitle: "Ch", isShort: true),
            Video(id: "srt10_FFFFF", title: "New1", channelTitle: "Ch", isShort: true),
            Video(id: "srt11_FFFFF", title: "New2", channelTitle: "Ch", isShort: true),
        ]
        mock.shortsResult = VideoGroup(title: "Shorts", videos: initialShorts, nextPageToken: "tok_dup")
        mock.shortsMoreResult = VideoGroup(title: "Shorts", videos: moreShorts, nextPageToken: nil)
        mock.homeRowsResult = []
        mock.subscriptionsResult = VideoGroup(title: "Subs", videos: [])

        let vm = HomeViewModel(api: mock)
        defer { vm.cancel() }
        vm.load()
        await waitForTasks(until: { vm.shortsVideos.count >= 5 })

        // 3 initial + 2 new (duplicate filtered out) = 5
        #expect(vm.shortsVideos.count == 5)
        let ids = Set(vm.shortsVideos.map(\.id))
        #expect(!ids.contains("srt0_EEEEE") == false) // original kept
        #expect(ids.contains("srt10_FFFFF"))
        #expect(ids.contains("srt11_FFFFF"))
    }

    @Test("preloadMoreShorts loops fetching pages until homeShortsVideos reaches the high threshold")
    func preloadMoreShortsLoopsUntilThreshold() async {
        let mock = MockInnerTubeAPI()
        let initialShorts = (0..<3).map { Video(id: "srt\($0)_AAAAA", title: "Short \($0)", channelTitle: "Ch", isShort: true) }
        mock.shortsResult = VideoGroup(title: "Shorts", videos: initialShorts, nextPageToken: "tok_0")
        mock.homeRowsResult = []
        mock.subscriptionsResult = VideoGroup(title: "Subs", videos: [])

        // Each call returns 5 fresh shorts plus a continuation token, so the
        // background preload loop must run several iterations to cross the
        // 40-item high threshold.
        var callCount = 0
        mock.shortsMoreHandler = { _ in
            callCount += 1
            let page = (0..<5).map { i in
                Video(id: "more\(callCount)_\(i)_GGGGG", title: "More \(callCount)-\(i)", channelTitle: "Ch", isShort: true)
            }
            return VideoGroup(title: "Shorts", videos: page, nextPageToken: "tok_\(callCount)")
        }

        let vm = HomeViewModel(api: mock)
        defer { vm.cancel() }
        vm.load()
        await waitForTasks()
        await waitForShortPreloadCompletion(vm)

        // 3 initial + repeated pages of 5 must reach the 40-item preload threshold.
        #expect(vm.homeShortsVideos.count >= 40)
        // Reaching 40 from 3 (+5/page) requires looping across multiple pages,
        // not just the single page loadMoreShortsIfNeeded fetches for its
        // own (lower) threshold.
        let shortsMoreCallCount = mock.calls.filter { $0.method == "fetchShortsMore" }.count
        #expect(shortsMoreCallCount >= 7)
    }

    @Test("preloadMoreShorts stops immediately when no continuation tokens remain")
    func preloadMoreShortsStopsWithNoTokens() async {
        let mock = MockInnerTubeAPI()
        let initialShorts = (0..<2).map { Video(id: "srt\($0)_HHHHH", title: "Short \($0)", channelTitle: "Ch", isShort: true) }
        // No continuation token from the initial fetch, and no subs section
        // continuation either — both sources are exhausted from the start.
        mock.shortsResult = VideoGroup(title: "Shorts", videos: initialShorts, nextPageToken: nil)
        mock.homeRowsResult = []
        mock.subscriptionsResult = VideoGroup(title: "Subs", videos: [])

        let vm = HomeViewModel(api: mock)
        defer { vm.cancel() }
        vm.load()
        await waitForTasks()
        await waitForShortPreloadCompletion(vm)

        // Below the 40-item threshold, but with no tokens left preload must
        // not call fetchShortsMore at all.
        #expect(vm.homeShortsVideos.count == 2)
        #expect(!mock.calls.contains(where: { $0.method == "fetchShortsMore" }))
    }

}

// MARK: - BrowseViewModelTests

@Suite("BrowseViewModel")
@MainActor
struct BrowseViewModelTests {

    @Test("loadContent for .subscriptions calls fetchSubscriptions and populates videoGroups")
    func loadSubscriptionsPopulatesGroups() async {
        let mock = MockInnerTubeAPI()
        mock.subscriptionsResult = VideoGroup(title: "Subs", videos: [makeVideo("subvid_AAAA")])

        let section = BrowseSection(id: "subscriptions", title: "Subscriptions", type: .subscriptions)
        let vm = BrowseViewModel(api: mock, initialSection: section)
        await vm.updateAuthToken("fake-token")  // authenticated path
        vm.loadContent(for: section, refresh: true, source: "test")
        await waitForTasks(until: { !vm.videoGroups.isEmpty })

        #expect(mock.calls.contains { $0.method == "fetchSubscriptions" })
        #expect(!vm.videoGroups.isEmpty)
        #expect(vm.videoGroups[0].videos[0].id == "subvid_AAAA")
    }

    @Test("loadContent for .history calls fetchHistory")
    func loadHistoryCallsFetch() async {
        let mock = MockInnerTubeAPI()
        mock.historyResult = VideoGroup(title: "History", videos: [makeVideo("histvid_AAAA")])

        let section = BrowseSection(id: "history", title: "History", type: .history)
        let vm = BrowseViewModel(api: mock, initialSection: section)
        vm.loadContent(for: section, refresh: true, source: "test")
        await waitForTasks(until: { vm.videoGroups.first?.videos.first != nil })

        #expect(mock.calls.contains { $0.method == "fetchHistory" })
        #expect(vm.videoGroups.first?.videos.first?.id == "histvid_AAAA")
    }

    @Test("Channels use the authenticated fetcher and shared stable catalogue policy")
    func loadChannelsUsesAuthenticatedSortedDeduplicatedResult() async {
        let mock = MockInnerTubeAPI()
        let avatar = URL(string: "https://example.invalid/avatar.jpg")!
        mock.channelsResult = [
            Channel(id: "z", title: "Яблоко", thumbnailURL: avatar),
            Channel(id: "a", title: "альфа", thumbnailURL: avatar),
            Channel(id: "a", title: "", thumbnailURL: avatar),
            Channel(id: "b", title: "Бета", thumbnailURL: avatar),
        ]

        let section = BrowseSection(type: .channels)
        let vm = BrowseViewModel(api: mock, initialSection: section)
        await vm.updateAuthToken("fake-token")
        await waitForTasks(until: { vm.subscribedChannels.count == 3 })

        #expect(mock.calls.contains { $0.method == "fetchSubscribedChannels" })
        #expect(vm.subscribedChannels.map(\.id) == ["a", "b", "z"])
        #expect(vm.videoGroups.isEmpty)
    }

    @Test("Empty subscriptions (local path) does not set isAuthRequired")
    func emptyLocalSubscriptionsDoNotSetAuthRequired() async {
        let mock = MockInnerTubeAPI()
        // No auth token → takes local path; local follows are empty

        let section = BrowseSection(id: "subscriptions", title: "Subscriptions", type: .subscriptions)
        let vm = BrowseViewModel(api: mock, initialSection: section)
        vm.loadContent(for: section, refresh: true, source: "test")
        await waitForTasks()

        // Local path never gates on auth — empty means "no follows yet", not "sign in"
        #expect(!vm.isAuthRequired)
    }

    @Test("loadContent for .shorts calls fetchShorts")
    func loadShortsCallsFetch() async {
        let mock = MockInnerTubeAPI()
        mock.shortsResult = VideoGroup(title: "Shorts", videos: [makeVideo("shortvid_AAAA")])

        let section = BrowseSection(id: "shorts", title: "Shorts", type: .shorts)
        let vm = BrowseViewModel(api: mock, initialSection: section)
        vm.loadContent(for: section, refresh: true, source: "test")
        await waitForTasks(until: { mock.calls.contains { $0.method == "fetchShorts" } })

        #expect(mock.calls.contains { $0.method == "fetchShorts" })
    }

    @Test("loadContent for .shorts with zero results normalizes videoGroups to empty")
    func loadShortsWithEmptyResultClearsVideoGroups() async {
        let mock = MockInnerTubeAPI()
        mock.shortsResult = VideoGroup(title: "Shorts", videos: [])

        let section = BrowseSection(id: "shorts", title: "Shorts", type: .shorts)
        let vm = BrowseViewModel(api: mock, initialSection: section)
        vm.loadContent(for: section, refresh: true, source: "test")
        await waitForTasks()

        // videoGroups must be [] (not [VideoGroup(videos: [])]) so the Home
        // Shorts chip's empty state ("Nothing here yet") can render — a
        // 1-element array with no videos is indistinguishable from "has content"
        // to sectionFeed's videoGroups.isEmpty check.
        #expect(vm.videoGroups.isEmpty)
    }

    @Test("Error on non-auth section sets error property")
    func errorOnFetchSetsErrorProperty() async {
        struct TestError: Error {}
        let mock = MockInnerTubeAPI()
        mock.errorToThrow = TestError()

        let section = BrowseSection(id: "shorts", title: "Shorts", type: .shorts)
        let vm = BrowseViewModel(api: mock, initialSection: section)
        vm.loadContent(for: section, refresh: true, source: "test")
        await waitForTasks(until: { vm.error != nil })

        #expect(vm.error != nil)
    }

    @Test("isLoading is false after fetch completes")
    func isLoadingFalseAfterFetch() async {
        let mock = MockInnerTubeAPI()
        mock.subscriptionsResult = VideoGroup(title: "Subs", videos: [makeVideo("vid_AAAAAAA")])

        let section = BrowseSection(id: "subscriptions", title: "Subscriptions", type: .subscriptions)
        let vm = BrowseViewModel(api: mock, initialSection: section)
        vm.loadContent(for: section, refresh: true, source: "test")
        // isLoading is false both before the fetch starts and after it ends, so
        // it can't be the polling condition on its own — and requiring a
        // recorded mock call doesn't work either, since unauthenticated
        // .subscriptions takes a local-store path that never calls the mock API
        // at all (see "Empty subscriptions (local path)" above). loadedAt is set
        // inside fetchSection's withThrowingTaskGroup body (BrowseViewModel.swift:475),
        // which can fire before the outer function (and its `defer { isLoading = false }`)
        // actually returns if other group children are still running — so require
        // both signals together rather than relying on loadedAt alone.
        await waitForTasks(until: { vm.loadedAt != nil && !vm.isLoading })

        #expect(!vm.isLoading)
    }
}

// MARK: - SearchViewModelTests

@Suite("SearchViewModel")
@MainActor
struct SearchViewModelTests {

    @Test("search() with non-empty query populates results")
    func searchPopulatesResults() async {
        let mock = MockInnerTubeAPI()
        mock.searchResult = VideoGroup(title: "Results", videos: [makeVideo("result_AAAAA")])

        let vm = makeSearchViewModel(api: mock)
        vm.query = "swift programming"
        vm.search()
        await waitForTasks()

        #expect(!vm.results.isEmpty)
        #expect(vm.results[0].id == "result_AAAAA")
    }

    @Test("search() with whitespace-only query is a no-op")
    func searchWithWhitespaceOnlyIsNoOp() async {
        let mock = MockInnerTubeAPI()
        mock.searchResult = VideoGroup(title: "Results", videos: [makeVideo("result_AAAAA")])

        let vm = makeSearchViewModel(api: mock)
        vm.query = "   "
        vm.search()
        await waitForTasks()

        #expect(vm.results.isEmpty)
        #expect(!mock.calls.contains { $0.method == "search" })
    }

    @Test("loadMore() with nextPageToken appends results")
    func loadMoreAppendsResults() async {
        let mock = MockInnerTubeAPI()
        let page1 = VideoGroup(title: "R", videos: [makeVideo("p1_0000001")], nextPageToken: "token123")
        let page2 = VideoGroup(title: "R", videos: [makeVideo("p2_0000002")])
        mock.searchResult = page1

        let vm = makeSearchViewModel(api: mock)
        vm.query = "test"
        vm.search()
        await waitForTasks()

        // Now set up page 2 and trigger loadMore
        mock.searchResult = page2
        vm.loadMore()
        await waitForTasks()

        #expect(vm.results.count == 2)
        let ids = vm.results.map(\.id)
        #expect(ids.contains("p1_0000001"))
        #expect(ids.contains("p2_0000002"))
    }

    @Test("isLoading is false after search completes")
    func isLoadingFalseAfterSearch() async {
        let mock = MockInnerTubeAPI()
        mock.searchResult = VideoGroup(title: "R", videos: [])

        let vm = makeSearchViewModel(api: mock)
        vm.query = "query"
        vm.search()
        await waitForTasks()

        #expect(!vm.isLoading)
    }

    @Test("applyFilter reruns search with new filter")
    func applyFilterReruns() async {
        let mock = MockInnerTubeAPI()
        mock.searchResult = VideoGroup(title: "R", videos: [makeVideo("vid_AAAAAAA")])

        let vm = makeSearchViewModel(api: mock)
        vm.query = "swift"
        vm.search()
        await waitForTasks()

        let beforeCount = mock.calls.filter { $0.method == "search" }.count
        var filter = SearchFilter()
        filter.sortOrder = .viewCount
        vm.applyFilter(filter)
        await waitForTasks()

        let afterCount = mock.calls.filter { $0.method == "search" }.count
        #expect(afterCount > beforeCount)
    }

    @Test("Clearing a completed query resets results pagination filter and discovery route")
    func clearQueryRestoresDiscovery() async {
        let mock = MockInnerTubeAPI()
        mock.searchResult = VideoGroup(
            title: "Results",
            videos: [makeVideo("old_result")],
            nextPageToken: "stale-token"
        )
        let vm = makeSearchViewModel(api: mock)
        vm.query = "Michael Naki"
        vm.search()
        await waitForTasks(until: { vm.results.count == 1 })
        var nonDefault = SearchFilter.default
        nonDefault.sortOrder = .viewCount
        vm.filter = nonDefault
        let previousDiscoveryGeneration = vm.discoveryGeneration

        vm.resetToDiscovery()
        vm.loadMore()

        #expect(vm.query.isEmpty)
        #expect(vm.activeQuery == nil)
        #expect(vm.results.isEmpty)
        #expect(vm.filter.isDefault)
        #expect(vm.discoveryGeneration == previousDiscoveryGeneration + 1)
        #expect(mock.calls.filter { $0.method == "search" }.count == 1)
    }

    @Test("Pull to refresh repeats a nonempty search from its first page")
    func refreshActiveQueryFromFirstPage() async {
        let mock = MockInnerTubeAPI()
        mock.searchResult = VideoGroup(
            title: "Results",
            videos: [makeVideo("old_result")],
            nextPageToken: "page-two"
        )
        let vm = makeSearchViewModel(api: mock)
        vm.query = "query"
        vm.search()
        await waitForTasks(until: { vm.results.first?.id == "old_result" })

        mock.searchResult = VideoGroup(title: "Results", videos: [makeVideo("fresh_result")])
        await vm.refreshSearch()

        #expect(vm.results.map(\.id) == ["fresh_result"])
        let searchCalls = mock.calls.filter { $0.method == "search" }
        #expect(searchCalls.count == 2)
        #expect(searchCalls.last?.args.last == "nil")
    }

    @Test("Empty-query refresh stays on discovery and never replays stale search")
    func refreshEmptyQueryUsesDiscoveryRoute() async {
        let mock = MockInnerTubeAPI()
        let vm = makeSearchViewModel(api: mock)
        vm.query = "   "
        await vm.refreshSearch()

        #expect(!vm.hasActiveSearch)
        #expect(vm.results.isEmpty)
        #expect(!mock.calls.contains { $0.method == "search" })
    }

    @Test("Initial search page compacts duplicate video IDs before SwiftUI layout")
    func firstPageDeduplicatesStableIDs() async {
        let mock = MockInnerTubeAPI()
        mock.searchResult = VideoGroup(title: "Results", videos: [
            makeVideo("same-id"),
            makeVideo("same-id"),
            makeVideo("unique-id"),
        ])
        let vm = makeSearchViewModel(api: mock)
        vm.query = "duplicates"
        vm.search()
        await waitForTasks(until: { !vm.isLoading && !vm.results.isEmpty })

        #expect(vm.results.map(\.id) == ["same-id", "unique-id"])
    }
}

// MARK: - PlaylistViewModelTests

@Suite("PlaylistViewModel")
@MainActor
struct PlaylistViewModelTests {

    @Test("load() fetches playlist videos and populates videos array")
    func loadPopulatesVideos() async {
        let mock = MockInnerTubeAPI()
        mock.playlistVideosResult = VideoGroup(title: "PL", videos: [
            makeVideo("plvid_AAAAA"),
            makeVideo("plvid_BBBBB"),
        ])

        let vm = PlaylistViewModel(api: mock)
        vm.load(playlistId: "PLtest1234567")
        await waitForTasks(until: { vm.videos.count == 2 })

        #expect(vm.videos.count == 2)
        #expect(mock.calls.contains { $0.method == "fetchPlaylistVideos" })
    }

    @Test("load() tags each video with playlistId")
    func loadTagsVideosWithPlaylistId() async {
        let mock = MockInnerTubeAPI()
        mock.playlistVideosResult = VideoGroup(title: "PL", videos: [makeVideo("vid_AAAAAAA")])

        let vm = PlaylistViewModel(api: mock)
        vm.load(playlistId: "PLtest1234567")
        await waitForTasks(until: { vm.videos.first != nil })

        #expect(vm.videos.first?.playlistId == "PLtest1234567")
    }

    @Test("load(refresh: true) clears videos and reloads")
    func loadRefreshClearsAndReloads() async {
        let mock = MockInnerTubeAPI()
        mock.playlistVideosResult = VideoGroup(title: "PL", videos: [makeVideo("vid_AAAAAAA")])

        let vm = PlaylistViewModel(api: mock)
        vm.load(playlistId: "PLtest1234567")
        await waitForTasks()

        // Refresh — should clear and re-fetch
        mock.playlistVideosResult = VideoGroup(title: "PL", videos: [makeVideo("vid_BBBBBBB")])
        vm.load(playlistId: "PLtest1234567", refresh: true)
        await waitForTasks()

        #expect(vm.videos.count == 1)
        #expect(vm.videos[0].id == "vid_BBBBBBB")
    }

    @Test("loadMoreIfNeeded appends next page when on last video")
    func loadMoreAppendsNextPage() async {
        let mock = MockInnerTubeAPI()
        let page1Video = makeVideo("page1_AAAAA")
        mock.playlistVideosResult = VideoGroup(
            title: "PL", videos: [page1Video], nextPageToken: "token_page2"
        )

        let vm = PlaylistViewModel(api: mock)
        vm.load(playlistId: "PLtest1234567")
        await waitForTasks()

        // Set up page 2
        mock.playlistVideosResult = VideoGroup(title: "PL", videos: [makeVideo("page2_BBBBB")])
        vm.loadMoreIfNeeded(lastVideo: page1Video)
        await waitForTasks()

        #expect(vm.videos.count == 2)
    }

    @Test("isLoading is false after fetch completes")
    func isLoadingFalseAfterFetch() async {
        let mock = MockInnerTubeAPI()
        mock.playlistVideosResult = VideoGroup(title: "PL", videos: [])

        let vm = PlaylistViewModel(api: mock)
        vm.load(playlistId: "PLtest1234567")
        await waitForTasks(until: { !vm.isLoading && !mock.calls.isEmpty })

        #expect(!vm.isLoading)
    }
}
