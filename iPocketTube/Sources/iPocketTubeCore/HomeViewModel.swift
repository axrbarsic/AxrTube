import Foundation
import Observation
import os

private let homeLog = ViewModelLogger(category: "Home")

// MARK: - HomeViewModel
//
// Fetches Subscriptions and Recommended shelves in parallel
// to populate the Home tab's multi-section feed.

@MainActor
@Observable
public final class HomeViewModel {

    private struct FetchResult: Sendable {
        var videos: [Video]
        var nextPageToken: String?
        var succeeded: Bool

        static let failed = FetchResult(videos: [], nextPageToken: nil, succeeded: false)
    }

    private struct SectionFetchResult: Sendable {
        var sectionID: String
        var type: BrowseSection.SectionType
        var requestedToken: String?
        var page: FetchResult
    }

    // MARK: - Section state

    public struct SectionState: Identifiable {
        public let section: BrowseSection
        public var videos: [Video] = []
        public var isLoading: Bool = true
        public var isLoadingMore: Bool = false
        public var hasFailed: Bool = false
        public var nextPageToken: String? = nil
        public var id: String { section.id }
    }

    // MARK: - State

    public private(set) var sections: [SectionState]
    /// Shorts fetched explicitly via FEshorts (TV home feed never includes them).
    public private(set) var shortsVideos: [Video] = []
    /// Continuation token from the last FEshorts fetch; used by loadMoreShortsIfNeeded.
    private var shortsNextPageToken: String? = nil
    private var isLoadingMoreShorts: Bool = false
    /// Background cascade started after `load()` finishes; keeps paging Shorts
    /// content toward `preloadMoreShorts`'s threshold. Cancelled on the next `load()`.
    private var shortsPreloadTask: Task<Void, Never>? = nil
    private var publicationEnrichmentTask: Task<Void, Never>? = nil
    private var mergedPaginationTask: Task<Void, Never>? = nil
    private var stateGeneration: UInt = 0
    private var paginationRequestKeys = Set<String>()
    public private(set) var isLoadingMoreMerged: Bool = false
    public private(set) var isRefreshing: Bool = false
    /// Timestamp of the last successful load. Used for staleness checks.
    public private(set) var loadedAt: Date? = nil
    /// Frozen snapshot of the interleaved home feed. Updated once both sections
    /// finish loading (avoiding mid-load rearrangement). Appended to during
    /// pagination without ever reordering existing items.
    public private(set) var mergedVideos: [Video] = []

    // MARK: - Shelf definitions (in display order)

    public static let shelfSections: [BrowseSection] = [
        BrowseSection(id: BrowseSection.SectionType.home.rawValue,          title: "Recommended",   type: .home),
        BrowseSection(id: BrowseSection.SectionType.subscriptions.rawValue, title: "Subscriptions", type: .subscriptions),
    ]

    /// `true` while either the recommended or subscriptions section is still on
    /// its initial load (no videos yet).  Used by the view to show a spinner.
    public var isLoadingAny: Bool {
        sections.contains { $0.isLoading }
    }

    public var hasMoreMerged: Bool {
        sections.contains {
            ($0.section.type == .home || $0.section.type == .subscriptions)
                && $0.nextPageToken != nil
        }
    }

    /// Builds one atomic snapshot from the two intentionally supported Home
    /// sources: YouTube recommendations and subscriptions.
    private func mergedSourceSnapshot() -> [Video] {
        let recState  = sections.first { $0.section.type == .home }
        let subState  = sections.first { $0.section.type == .subscriptions }
        let recs  = recState?.videos  ?? []
        let subs  = subState?.videos  ?? []
        var seen = Set<String>()
        let deduped = (recs + subs).filter { seen.insert($0.id).inserted }
        return VideoPublicationSortPolicy.sorted(deduped, for: .home)
    }

    /// Produces the refreshed source snapshot in one commit. Cards that still
    /// exist retain their stable YouTube identity and best publication metadata;
    /// entries no longer returned by either supported source are removed instead
    /// of contaminating the feed forever.
    private static func refreshingStableSnapshot(
        existing: [Video],
        refreshed: [Video]
    ) -> [Video] {
        let existingByID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
        return refreshed.map { video in
            guard let previous = existingByID[video.id] else { return video }
            return VideoPublicationSortPolicy.mergingPublicationMetadata(
                base: video,
                candidate: previous
            )
        }
    }

    /// Updates publication metadata without changing identities or positions,
    /// then appends only genuinely new page entries in their page chronology.
    /// A continuation must never rebuild the already-visible prefix.
    private static func orderedAppend(
        existing: [Video],
        page: [Video],
        route: VideoListRoute
    ) -> (videos: [Video], appended: [Video]) {
        let metadata = VideoPublicationSortPolicy.metadataByVideoID(existing + page)
        let patchedExisting = existing.map { video -> Video in
            guard let candidate = metadata[video.id] else { return video }
            return VideoPublicationSortPolicy.mergingPublicationMetadata(
                base: video,
                candidate: candidate
            )
        }
        var seen = Set(patchedExisting.map(\.id))
        let uniquePage = VideoPublicationSortPolicy.sorted(page, for: route)
            .filter { !$0.id.isEmpty && seen.insert($0.id).inserted }
        return (patchedExisting + uniquePage, uniquePage)
    }

    /// Non-Short videos from the interleaved home feed.
    /// Used by `homeShelves` to populate the main grid (Shorts are shown separately).
    public var homeRegularVideos: [Video] { mergedVideos.filter { !$0.isShort } }

    /// Short videos for the dedicated Shorts row.
    /// Sources (in priority order, deduplicated by video ID):
    ///  1. `shortsVideos` — from the FEshorts browse (when the API works)
    ///  2. Subscriptions section shorts — pulled directly from the full subs list so
    ///     they are not lost to the home/subs interleave ratio in `mergedVideos`
    ///  3. `mergedVideos` shorts — catches any shorts from the home-rec feed
    public var homeShortsVideos: [Video] {
        let subsShorts = sections.first { $0.section.type == .subscriptions }?.videos.filter { $0.isShort } ?? []
        var seen = Set<String>()
        return (shortsVideos + subsShorts + mergedVideos.filter { $0.isShort })
            .filter { seen.insert($0.id).inserted }
    }

    // MARK: - Dependencies

    private let api: any InnerTubeAPIProtocol
    private var loadTask: Task<Void, Never>?
    private var hideObserverTasks: [Task<Void, Never>] = []
    /// Tracks whether a non-nil auth token has been set. Used to distinguish a
    /// sign-in event (nil → non-nil) from a token refresh (non-nil → new non-nil)
    /// so that token refreshes during video playback do not trigger a feed reload.
    private var hasAuthToken: Bool = false

    public init(api: any InnerTubeAPIProtocol = InnerTubeAPI()) {
        self.api = api
        self.sections = Self.shelfSections.map { SectionState(section: $0) }
        observeFeedHideNotifications()
    }

    // MARK: - Feed hide handling

    private func observeFeedHideNotifications() {
        hideObserverTasks.append(Task { [weak self] in
            for await note in NotificationCenter.default.notifications(named: .hideVideoFromFeed) {
                guard let self, let videoId = note.userInfo?["videoId"] as? String else { continue }
                self.removeVideo(id: videoId)
            }
        })
        hideObserverTasks.append(Task { [weak self] in
            for await note in NotificationCenter.default.notifications(named: .hideChannelFromFeed) {
                guard let self, let channelId = note.userInfo?["channelId"] as? String else { continue }
                self.removeChannel(id: channelId)
            }
        })
    }

    public func removeVideo(id: String) {
        for i in sections.indices {
            sections[i].videos.removeAll { $0.id == id }
        }
        mergedVideos.removeAll { $0.id == id }
    }

    public func removeChannel(id: String) {
        for i in sections.indices {
            sections[i].videos.removeAll { $0.channelId == id }
        }
        mergedVideos.removeAll { $0.channelId == id }
    }

    /// Cancels all in-flight and background work (the main load task, the
    /// Shorts preload loop, and the feed-hide notification observers). Callers
    /// that create short-lived `HomeViewModel` instances — e.g. tests — should
    /// call this when done to avoid orphaned tasks bleeding state into later use.
    public func cancel() {
        stateGeneration &+= 1
        loadTask?.cancel()
        mergedPaginationTask?.cancel()
        shortsPreloadTask?.cancel()
        publicationEnrichmentTask?.cancel()
        isRefreshing = false
        isLoadingMoreMerged = false
        for index in sections.indices {
            sections[index].isLoading = false
            sections[index].isLoadingMore = false
        }
        hideObserverTasks.forEach { $0.cancel() }
    }

    // MARK: - Public API

    public func load() {
        stateGeneration &+= 1
        let generation = stateGeneration
        let isInitialLoad = mergedVideos.isEmpty
        loadTask?.cancel()
        mergedPaginationTask?.cancel()
        shortsPreloadTask?.cancel()
        publicationEnrichmentTask?.cancel()
        paginationRequestKeys.removeAll(keepingCapacity: true)
        isLoadingMoreMerged = false
        isRefreshing = true
        for i in sections.indices {
            if isInitialLoad {
                sections[i].videos = []
                sections[i].nextPageToken = nil
                sections[i].hasFailed = false
            }
            sections[i].isLoading = true
            sections[i].isLoadingMore = false
        }

        loadTask = Task { [weak self] in
            guard let self else { return }
            // Fetch shorts via FEshorts in parallel with the home/subs feed.
            // The TV home feed (FEwhat_to_watch) never includes a Shorts shelf.
            async let fetchedShortsResult = HomeViewModel.fetchShortsVideos(api: self.api)

            let sectionResults = await withTaskGroup(
                of: SectionFetchResult.self,
                returning: [String: SectionFetchResult].self
            ) { group in
                for state in self.sections {
                    let sectionId = state.id
                    let type = state.section.type
                    let api = self.api
                    group.addTask {
                        SectionFetchResult(
                            sectionID: sectionId,
                            type: type,
                            requestedToken: nil,
                            page: await HomeViewModel.fetchVideos(type: type, api: api)
                        )
                    }
                }
                var collected: [String: SectionFetchResult] = [:]
                for await result in group {
                    collected[result.sectionID] = result
                }
                return collected
            }

            let fetchedShorts = await fetchedShortsResult
            guard !Task.isCancelled, generation == self.stateGeneration else { return }

            var loadedAnySection = false
            for index in self.sections.indices {
                let sectionID = self.sections[index].id
                if let result = sectionResults[sectionID], result.page.succeeded {
                    self.sections[index].videos = result.page.videos
                    self.sections[index].nextPageToken = result.page.nextPageToken
                    self.sections[index].hasFailed = false
                    loadedAnySection = true
                } else {
                    // A transient refresh failure must not destroy the last visible
                    // snapshot or its continuation cursor.
                    self.sections[index].hasFailed = self.sections[index].videos.isEmpty
                }
                self.sections[index].isLoading = false
                self.sections[index].isLoadingMore = false
            }
            if loadedAnySection || isInitialLoad {
                let refreshedSnapshot = self.mergedSourceSnapshot()
                self.mergedVideos = isInitialLoad
                    ? refreshedSnapshot
                    : Self.refreshingStableSnapshot(
                        existing: self.mergedVideos,
                        refreshed: refreshedSnapshot
                    )
            }
            if fetchedShorts.succeeded {
                self.shortsVideos = VideoPublicationSortPolicy.sorted(fetchedShorts.videos, for: .home)
                self.shortsNextPageToken = fetchedShorts.nextPageToken
            }
            // Fill the initial threshold (6 iOS / 8 tvOS) quickly.
            // Further pages are loaded lazily as the user scrolls to the last card.
            await self.loadMoreShortsIfNeeded(generation: generation)
            guard !Task.isCancelled, generation == self.stateGeneration else { return }
            self.isRefreshing = false
            if loadedAnySection { self.loadedAt = Date() }
            self.schedulePublicationEnrichment(generation: generation)
            let merged = self.mergedVideos
            let mergedShorts = merged.filter { $0.isShort }.count
            homeLog.notice("load complete: merged=\(merged.count) regular=\(merged.count - mergedShorts) mergedShorts=\(mergedShorts) shortsSection=\(shortsVideos.count)")
            // Keep paging Shorts content in the background toward preloadMoreShorts's
            // higher threshold, without delaying the load completion above.
            self.shortsPreloadTask = Task { @MainActor [weak self] in
                await self?.preloadMoreShorts(generation: generation)
            }
        }
    }

    /// Keeps SwiftUI's pull-to-refresh indicator alive until the atomic refresh
    /// commit (or a superseding generation) completes.
    public func refresh() async {
        load()
        await loadTask?.value
    }

    public func updateAuthToken(_ token: String?) async {
        let wasAuthenticated = hasAuthToken
        hasAuthToken = token != nil
        await api.setAuthToken(token)
        if token != nil && !wasAuthenticated {
            // Only reload on sign-in (nil → token). Token refreshes that happen
            // during video playback keep the same sign-in state and must not
            // wipe and reload the home feed.
            load()
        }
    }

    /// Refreshes both shelves if the last successful load was more than
    /// `threshold` seconds ago (default 15 min). No-op while loading.
    public func refreshIfStale(threshold: TimeInterval = 15 * 60) {
        guard !isRefreshing else { return }
        let age = loadedAt.map { Date().timeIntervalSince($0) } ?? .infinity
        guard age > threshold else { return }
        let ageDesc = age.isFinite ? "\(Int(age))s" : "never loaded"
        homeLog.notice("refreshIfStale: age=\(ageDesc) — reloading shelves")
        load()
    }

    // MARK: - Pagination

    private func enrichedSectionSnapshots(_ snapshots: [[Video]]) async -> [[Video]] {
        let all = snapshots.flatMap { $0 }
        let enriched = await VideoPublicationDateEnricher.shared.enrich(all) { [api] id in
            try? await api.fetchExactPublicationDate(videoId: id)
        }
        let metadata = VideoPublicationSortPolicy.metadataByVideoID(enriched)
        return snapshots.map { videos in
            videos.map { video -> Video in
                guard let source = metadata[video.id] else { return video }
                return VideoPublicationSortPolicy.mergingPublicationMetadata(base: video, candidate: source)
            }
        }
    }

    private func schedulePublicationEnrichment(generation: UInt) {
        publicationEnrichmentTask?.cancel()
        let sectionSnapshots = sections.map(\.videos)
        let sectionIDs = sectionSnapshots.map { $0.map(\.id) }
        let shortsSnapshot = shortsVideos
        let mergedIDs = mergedVideos.map(\.id)
        publicationEnrichmentTask = Task { [weak self] in
            guard let self else { return }
            let enrichedSections = await self.enrichedSectionSnapshots(sectionSnapshots)
            let enrichedShorts = await VideoPublicationDateEnricher.shared.enrich(shortsSnapshot) { [api] id in
                try? await api.fetchExactPublicationDate(videoId: id)
            }
            guard !Task.isCancelled,
                  generation == self.stateGeneration,
                  self.sections.map({ $0.videos.map(\.id) }) == sectionIDs,
                  self.mergedVideos.map(\.id) == mergedIDs else { return }
            for index in self.sections.indices where index < enrichedSections.count {
                self.sections[index].videos = enrichedSections[index]
            }
            let metadata = VideoPublicationSortPolicy.metadataByVideoID(
                enrichedSections.flatMap { $0 } + enrichedShorts
            )
            self.shortsVideos = self.shortsVideos.map { video in
                guard let candidate = metadata[video.id] else { return video }
                return VideoPublicationSortPolicy.mergingPublicationMetadata(base: video, candidate: candidate)
            }
            self.mergedVideos = self.mergedVideos.map { video in
                guard let candidate = metadata[video.id] else { return video }
                return VideoPublicationSortPolicy.mergingPublicationMetadata(base: video, candidate: candidate)
            }
        }
    }

    /// Called by the merged home feed when the user scrolls near the bottom.
    /// Pages both the recommended and subscriptions sections simultaneously so
    /// the interleaved list keeps growing evenly.
    public func loadMoreMerged(triggeredBy sentinelID: String?) {
        guard let sentinelID, !sentinelID.isEmpty,
              !isRefreshing,
              !isLoadingMoreMerged else { return }

        let requests = sections.compactMap { state -> (String, BrowseSection.SectionType, String)? in
            guard (state.section.type == .home || state.section.type == .subscriptions),
                  !state.isLoading,
                  let token = state.nextPageToken else { return nil }
            return (state.id, state.section.type, token)
        }
        guard !requests.isEmpty else { return }

        // A visible sentinel may receive onAppear repeatedly while SwiftUI
        // reconciles loading flags or metadata. It is permitted exactly once
        // per stable last-card identity in this feed generation. A changed
        // continuation cursor alone must not recursively page a still-visible
        // sentinel; successful append changes the sentinel ID naturally.
        let requestKey = "\(stateGeneration)|\(sentinelID)"
        guard paginationRequestKeys.insert(requestKey).inserted else { return }

        let generation = stateGeneration
        isLoadingMoreMerged = true
        for index in sections.indices where requests.contains(where: { $0.0 == sections[index].id }) {
            sections[index].isLoadingMore = true
        }

        mergedPaginationTask?.cancel()
        mergedPaginationTask = Task { [weak self] in
            guard let self else { return }
            let results = await withTaskGroup(of: SectionFetchResult.self, returning: [SectionFetchResult].self) { group in
                for request in requests {
                    let api = self.api
                    group.addTask {
                        SectionFetchResult(
                            sectionID: request.0,
                            type: request.1,
                            requestedToken: request.2,
                            page: await HomeViewModel.fetchMoreVideos(
                                type: request.1,
                                token: request.2,
                                api: api
                            )
                        )
                    }
                }
                var pages: [SectionFetchResult] = []
                for await result in group { pages.append(result) }
                return pages
            }

            guard !Task.isCancelled, generation == self.stateGeneration else { return }
            var appendedToMerged: [Video] = []
            for result in results.sorted(by: { $0.sectionID < $1.sectionID }) {
                guard let index = self.sections.firstIndex(where: { $0.id == result.sectionID }),
                      self.sections[index].nextPageToken == result.requestedToken else { continue }
                defer { self.sections[index].isLoadingMore = false }
                guard result.page.succeeded else { continue }

                let route: VideoListRoute = result.type == .subscriptions ? .subscriptions : .home
                let append = Self.orderedAppend(
                    existing: self.sections[index].videos,
                    page: result.page.videos,
                    route: route
                )
                self.sections[index].videos = append.videos
                appendedToMerged.append(contentsOf: append.appended)

                // Empty pages and repeated cursors cannot make forward progress;
                // exhausting them prevents an always-visible sentinel loop.
                if append.appended.isEmpty || result.page.nextPageToken == result.requestedToken {
                    self.sections[index].nextPageToken = nil
                } else {
                    self.sections[index].nextPageToken = result.page.nextPageToken
                }
            }

            let mergedAppend = Self.orderedAppend(
                existing: self.mergedVideos,
                page: appendedToMerged,
                route: .home
            )
            self.mergedVideos = mergedAppend.videos
            self.isLoadingMoreMerged = false
            self.mergedPaginationTask = nil
            self.schedulePublicationEnrichment(generation: generation)
        }
    }

    /// Called by the view when the user scrolls to the last card in the Shorts row.
    /// Loads the next page unconditionally — no minimum-count threshold — so the row
    /// grows on demand as the user scrolls past the already-loaded cards.
    public func loadNextShortsPage() {
        homeLog.notice("loadNextShortsPage: called — count=\(shortsVideos.count) isLoading=\(isLoadingMoreShorts) searchToken=\(shortsNextPageToken != nil)")
        guard !isLoadingMoreShorts, shortsNextPageToken != nil else {
            homeLog.notice("loadNextShortsPage: skipped — no tokens available")
            return
        }
        let generation = stateGeneration
        Task { @MainActor [weak self] in
            await self?.fetchAndAppendNextShortsPage(generation: generation)
        }
    }

    private func fetchAndAppendNextShortsPage(generation: UInt) async {
        guard generation == stateGeneration,
              !isLoadingMoreShorts,
              shortsNextPageToken != nil else { return }
        isLoadingMoreShorts = true
        defer { isLoadingMoreShorts = false }
        _ = await fetchOneShortsPage(generation: generation)
    }

    /// Fetches one increment of Shorts content: a FEshorts search-continuation page
    /// if available. The subscriptions continuation belongs exclusively to the
    /// merged Home paginator; consuming it here would skip or reorder regular
    /// feed pages.
    /// Returns `true` if any new videos were appended.
    private func fetchOneShortsPage(generation: UInt) async -> Bool {
        guard generation == stateGeneration, let token = shortsNextPageToken else { return false }
        homeLog.notice("fetchOneShortsPage search: fetching next page")
        do {
            let more = try await api.fetchShortsMore(continuationToken: token)
            guard generation == stateGeneration, !Task.isCancelled else { return false }
            var seen = Set(shortsVideos.map(\.id))
            let newVideos = more.videos.filter { !$0.id.isEmpty && seen.insert($0.id).inserted }
            shortsVideos.append(contentsOf: newVideos)
            shortsNextPageToken = more.nextPageToken == token ? nil : more.nextPageToken
            homeLog.notice("fetchOneShortsPage search: added \(newVideos.count) total=\(shortsVideos.count) hasMore=\(shortsNextPageToken != nil)")
            return !newVideos.isEmpty
        } catch {
            guard generation == stateGeneration else { return false }
            homeLog.error("fetchOneShortsPage search: failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Auto-loads an additional page of FEshorts if the current count falls below
    /// the threshold needed to fill 2 horizontal screens.
    /// iOS: ~3 cards/screen → threshold = 6; tvOS: ~4 cards/screen → threshold = 8.
    func loadMoreShortsIfNeeded(generation: UInt? = nil) async {
        let generation = generation ?? stateGeneration
        #if os(tvOS)
        let threshold = 8
        #else
        let threshold = 6
        #endif
        guard !isLoadingMoreShorts else {
            homeLog.notice("loadMoreShortsIfNeeded: skipped — already loading")
            return
        }
        guard shortsVideos.count < threshold, shortsNextPageToken != nil else {
            homeLog.notice("loadMoreShortsIfNeeded: skipped count=\(shortsVideos.count) hasToken=\(shortsNextPageToken != nil) loading=\(isLoadingMoreShorts)")
            return
        }
        isLoadingMoreShorts = true
        defer { isLoadingMoreShorts = false }
        var loopIteration = 0
        // Loop until we have at least `threshold` items or pages run out.
        while generation == stateGeneration,
              !Task.isCancelled,
              shortsVideos.count < threshold,
              shortsNextPageToken != nil {
            loopIteration += 1
            homeLog.notice("loadMoreShortsIfNeeded: loop=\(loopIteration) count=\(shortsVideos.count) threshold=\(threshold)")
            guard await fetchOneShortsPage(generation: generation) else { break }
        }
    }

    /// Continues fetching dedicated Shorts pages in the background until
    /// `homeShortsVideos.count` reaches `preloadHighThreshold`. Started as a
    /// fire-and-forget task after `load()` finishes its fast initial fill
    /// (`loadMoreShortsIfNeeded`), so the Shorts row keeps growing for an
    /// endless-scroll experience without delaying `isRefreshing = false`.
    private func preloadMoreShorts(generation: UInt) async {
        #if os(tvOS)
        let preloadHighThreshold = 50
        #else
        let preloadHighThreshold = 40
        #endif
        guard !isLoadingMoreShorts else { return }
        isLoadingMoreShorts = true
        defer { isLoadingMoreShorts = false }
        var loopIteration = 0
        while generation == stateGeneration,
              !Task.isCancelled,
              homeShortsVideos.count < preloadHighThreshold {
            guard shortsNextPageToken != nil else {
                homeLog.notice("preloadMoreShorts: stopping — no continuation tokens left, count=\(homeShortsVideos.count)")
                break
            }
            loopIteration += 1
            homeLog.notice("preloadMoreShorts: iteration=\(loopIteration) count=\(homeShortsVideos.count)/\(preloadHighThreshold)")
            guard await fetchOneShortsPage(generation: generation) else {
                homeLog.notice("preloadMoreShorts: stopping — page returned no new videos")
                break
            }
        }
    }

    // MARK: - Private fetch helpers

    /// Fetches the FEshorts feed. Non-isolated so it runs concurrently with
    /// the home/subs task group.
    private static func fetchShortsVideos(api: any InnerTubeAPIProtocol) async -> FetchResult {
        do {
            let group = try await api.fetchShorts()
            let hasToken = group.nextPageToken != nil
            homeLog.notice("fetchShortsVideos → \(group.videos.count) shorts hasToken=\(hasToken)")
            return FetchResult(videos: group.videos, nextPageToken: group.nextPageToken, succeeded: true)
        } catch {
            homeLog.error("fetchShortsVideos failed: \(error.localizedDescription)")
            return .failed
        }
    }

    /// Non-isolated so child tasks run on the global executor and network
    /// calls can overlap.
    private static func fetchVideos(type: BrowseSection.SectionType, api: any InnerTubeAPIProtocol) async -> FetchResult {
        do {
            switch type {
            case .subscriptions:
                let group = try await api.fetchSubscriptions()
                let shortsCount = group.videos.filter { $0.isShort }.count
                homeLog.notice("fetchVideos subs: total=\(group.videos.count) shorts=\(shortsCount) regular=\(group.videos.count - shortsCount)")
                return FetchResult(
                    videos: Array(group.videos.prefix(InnerTubeClients.maxVideoResults)),
                    nextPageToken: group.nextPageToken,
                    succeeded: true
                )
            case .home:
                let rows = try await api.fetchHomeRows()
                let token = rows.last(where: { $0.nextPageToken != nil })?.nextPageToken
                var seen = Set<String>()
                let deduped = rows.flatMap(\.videos).filter { seen.insert($0.id).inserted }
                let fetchedShortsCount = deduped.filter { $0.isShort }.count
                homeLog.notice("fetchVideos home: total=\(deduped.count) shorts=\(fetchedShortsCount) regular=\(deduped.count - fetchedShortsCount)")
                // Empty Home is an honest Home state. Injecting a generic
                // `popular` search here mixed a separate catalog (including
                // movie results) into the authenticated YouTube feed.
                return FetchResult(
                    videos: Array(deduped.prefix(InnerTubeClients.maxVideoResults)),
                    nextPageToken: token,
                    succeeded: true
                )
            default:
                return FetchResult(videos: [], nextPageToken: nil, succeeded: true)
            }
        } catch {
            homeLog.error("HomeViewModel fetch \(String(describing: type)): \(error.localizedDescription)")
            return .failed
        }
    }

    private static func fetchMoreVideos(type: BrowseSection.SectionType, token: String, api: any InnerTubeAPIProtocol) async -> FetchResult {
        do {
            switch type {
            case .subscriptions:
                let group = try await retryWithBackoff(label: "HomeVM.subs") {
                    try await api.fetchSubscriptions(continuationToken: token)
                }
                let shortsCount = group.videos.filter { $0.isShort }.count
                homeLog.notice("fetchMoreVideos subs: total=\(group.videos.count) shorts=\(shortsCount) regular=\(group.videos.count - shortsCount)")
                return FetchResult(videos: group.videos, nextPageToken: group.nextPageToken, succeeded: true)
            case .home:
                let rows = try await retryWithBackoff(label: "HomeVM.home") {
                    try await api.fetchHomeRows(continuationToken: token)
                }
                let nextToken = rows.last(where: { $0.nextPageToken != nil })?.nextPageToken
                // Dedup within the page — YouTube can return the same video ID
                // in multiple shelves of the same continuation response.
                var seen = Set<String>()
                let deduped = rows.flatMap(\.videos).filter { seen.insert($0.id).inserted }
                return FetchResult(videos: deduped, nextPageToken: nextToken, succeeded: true)
            default:
                return FetchResult(videos: [], nextPageToken: nil, succeeded: true)
            }
        } catch {
            homeLog.error("HomeViewModel loadMore \(String(describing: type)): \(error.localizedDescription)")
            return .failed
        }
    }
}
