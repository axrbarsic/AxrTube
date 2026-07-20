import Foundation
import Observation

// MARK: - SearchViewModel
//
// Mirrors the Android `SearchPresenter`.

@MainActor
@Observable
public final class SearchViewModel {

    public var query: String = ""
    public var filter: SearchFilter = .default
    public private(set) var activeQuery: String?
    public private(set) var discoveryGeneration: Int = 0
    public private(set) var results: [Video] = []
    public private(set) var suggestions: [String] = []
    public private(set) var history: [SearchHistoryEntry] = []
    public private(set) var isLoading: Bool = false
    public private(set) var russianOnlySearchEnabled: Bool = true
    public var error: Error?

    private let api: any InnerTubeAPIProtocol
    private let historyStore: SearchHistoryStore
    private var nextPageToken: String?
    private var searchTask: Task<Void, Never>?
    private var publicationTask: Task<Void, Never>?
    private var suggestTask: Task<Void, Never>?
    private var hideObserverTasks: [Task<Void, Never>] = []
    private var searchGeneration: UInt = 0
    private static let strictSearchPageBudget = 3
    private static let strictSearchTargetCount = 8
    private static let languageEnrichmentConcurrency = 4

    public var hasActiveSearch: Bool { activeQuery != nil }

    /// History entries that match the current query (case-insensitive). Returns
    /// the full history when the query is empty.
    public var filteredHistory: [SearchHistoryEntry] {
        guard !query.isEmpty else { return history }
        return history.filter { $0.query.localizedCaseInsensitiveContains(query) }
    }

    public init(api: any InnerTubeAPIProtocol = InnerTubeAPI(), historyStore: SearchHistoryStore = .shared) {
        self.api = api
        self.historyStore = historyStore
        Task { await loadHistory() }
        observeFeedHideNotifications()
    }

    /// Call from `.task(id: query)` in the view to debounce live suggestions.
    /// An empty query shows real local history and the discovery feed. We never
    /// manufacture static English recommendations.
    public func updateSuggestions(for q: String) async {
        print("[Suggestions] updateSuggestions called, q='\(q)'")
        if q.isEmpty {
            suggestTask?.cancel()
            suggestions = []
            return
        }
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled else {
            print("[Suggestions] Task cancelled before fetch")
            return
        }
        fetchSuggestions(for: q)
    }

    public func search() {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            resetToDiscovery()
            return
        }
        beginSearch(query: trimmed, recordHistory: true)
    }

    /// Clears every state owned by the search route. This is deliberately more
    /// than setting the editor text to empty: stale pagination, filters and late
    /// callbacks must not keep the old results surface alive as discovery.
    public func resetToDiscovery() {
        searchGeneration &+= 1
        searchTask?.cancel()
        publicationTask?.cancel()
        suggestTask?.cancel()
        query = ""
        activeQuery = nil
        filter = .default
        results = []
        suggestions = []
        nextPageToken = nil
        error = nil
        isLoading = false
        discoveryGeneration &+= 1
    }

    /// Pull-to-refresh for active results. Empty-query discovery owns its own
    /// HomeView refreshable and therefore returns without issuing a search.
    public func refreshSearch() async {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            resetToDiscovery()
            return
        }
        searchGeneration &+= 1
        let generation = searchGeneration
        searchTask?.cancel()
        publicationTask?.cancel()
        activeQuery = trimmed
        results = []
        nextPageToken = nil
        error = nil
        let task = Task { await performSearch(query: trimmed, filter: filter, generation: generation) }
        searchTask = task
        await task.value
    }

    private func beginSearch(query trimmed: String, recordHistory: Bool) {
        searchGeneration &+= 1
        let generation = searchGeneration
        activeQuery = trimmed
        query = trimmed
        results = []
        nextPageToken = nil
        error = nil
        searchTask?.cancel()
        publicationTask?.cancel()
        searchTask = Task { await performSearch(query: trimmed, filter: filter, generation: generation) }
        if recordHistory { Task { await recordSearch(trimmed) } }
    }

    // MARK: - History management

    /// Loads history from the store into the published `history` property.
    public func loadHistory() async {
        history = await historyStore.all
    }

    /// Saves `query` to history and refreshes the in-memory list.
    private func recordSearch(_ query: String) async {
        await historyStore.add(query)
        history = await historyStore.all
    }

    /// Removes a single entry from history.
    public func removeHistoryEntry(_ query: String) {
        Task {
            await historyStore.remove(query)
            history = await historyStore.all
        }
    }

    /// Clears all history entries.
    public func clearHistory() {
        Task {
            await historyStore.clear()
            history = await historyStore.all
        }
    }

    /// Apply a new filter and re-run the current search immediately.
    public func applyFilter(_ newFilter: SearchFilter) {
        filter = newFilter
        guard let activeQuery else { return }
        beginSearch(query: activeQuery, recordHistory: false)
    }

    /// Applies the persisted setting live. An active query is restarted from page one
    /// so unrestricted and strict result sets can never contaminate each other.
    public func setRussianOnlySearchEnabled(_ enabled: Bool) {
        guard russianOnlySearchEnabled != enabled else { return }
        russianOnlySearchEnabled = enabled
        guard let activeQuery else { return }
        beginSearch(query: activeQuery, recordHistory: false)
    }

    public func loadMore() {
        guard let activeQuery, let token = nextPageToken, !isLoading else { return }
        let generation = searchGeneration
        searchTask = Task {
            await performSearch(
                query: activeQuery,
                continuationToken: token,
                filter: filter,
                generation: generation
            )
        }
    }

    private func performSearch(
        query: String,
        continuationToken: String? = nil,
        filter: SearchFilter = .default,
        generation: UInt
    ) async {
        guard generation == searchGeneration else { return }
        isLoading = true
        defer {
            if generation == searchGeneration { isLoading = false }
        }
        do {
            let preference: SearchLanguagePreference = russianOnlySearchEnabled ? .russian : .unrestricted
            var token = continuationToken
            var accepted: [Video] = []
            var pagesFetched = 0

            repeat {
                let requestToken = token
                let group = try await retryWithBackoff(label: "SearchVM") {
                    try await api.search(
                        query: query,
                        continuationToken: requestToken,
                        filter: filter,
                        languagePreference: preference
                    )
                }
                guard !Task.isCancelled,
                      generation == searchGeneration,
                      activeQuery == query else { return }

                if preference == .russian {
                    accepted.append(contentsOf: await russianVideos(from: group.videos))
                } else {
                    accepted.append(contentsOf: group.videos)
                }
                token = group.nextPageToken
                pagesFetched += 1
            } while preference == .russian
                && accepted.count < Self.strictSearchTargetCount
                && token != nil
                && pagesFetched < Self.strictSearchPageBudget

            guard !Task.isCancelled,
                  generation == searchGeneration,
                  activeQuery == query else { return }
            if continuationToken == nil {
                results = VideoPublicationSortPolicy.merging(
                    existing: [],
                    page: accepted,
                    for: .search
                )
            } else {
                results = VideoPublicationSortPolicy.merging(
                    existing: results,
                    page: accepted,
                    for: .search
                )
            }
            nextPageToken = token
            schedulePublicationEnrichment(generation: generation)
        } catch {
            if !Task.isCancelled, generation == searchGeneration { self.error = error }
        }
    }

    /// Enriches a page in bounded batches. The cache coalesces duplicate video IDs
    /// across pagination and repeated searches; the final result is published once.
    private func russianVideos(from videos: [Video]) async -> [Video] {
        var evidenceByID: [String: VideoLanguageEvidence] = [:]
        var start = videos.startIndex
        while start < videos.endIndex {
            let end = videos.index(start, offsetBy: Self.languageEnrichmentConcurrency, limitedBy: videos.endIndex)
                ?? videos.endIndex
            let batch = Array(videos[start..<end])
            await withTaskGroup(of: (String, VideoLanguageEvidence).self) { group in
                for video in batch {
                    group.addTask { [api] in
                        let evidence = await VideoLanguageEvidenceCache.shared.evidence(for: video.id) {
                            (try? await api.fetchVideoLanguageEvidence(videoId: video.id)) ?? .init()
                        }
                        return (video.id, evidence)
                    }
                }
                for await (id, evidence) in group { evidenceByID[id] = evidence }
            }
            if Task.isCancelled { return [] }
            start = end
        }

        return videos.filter {
            VideoLanguageClassifier.includes(
                evidence: evidenceByID[$0.id] ?? .init(),
                preference: .russian
            )
        }
    }

    private func schedulePublicationEnrichment(generation: UInt) {
        publicationTask?.cancel()
        let snapshot = results
        let expectedIDs = snapshot.map(\.id)
        publicationTask = Task { [weak self, api] in
            let enriched = await VideoPublicationDateEnricher.shared.enrich(snapshot) { id in
                try? await api.fetchExactPublicationDate(videoId: id)
            }
            guard let self,
                  !Task.isCancelled,
                  generation == self.searchGeneration,
                  self.results.map(\.id) == expectedIDs else { return }
            self.results = VideoPublicationSortPolicy.sorted(enriched, for: .search)
        }
    }

    private func fetchSuggestions(for requestedQuery: String) {
        print("[Suggestions] fetchSuggestions spawning task for q='\(requestedQuery)'")
        suggestTask?.cancel()
        suggestTask = Task {
            do {
                let s = try await api.fetchSearchSuggestions(query: requestedQuery)
                guard !Task.isCancelled, self.query == requestedQuery else {
                    print("[Suggestions] Task cancelled after fetch")
                    return
                }
                let result = s
                print("[Suggestions] Setting \(result.count) suggestions")
                suggestions = result
            } catch {
                print("[Suggestions] fetchSearchSuggestions threw: \(error)")
                if !Task.isCancelled { suggestions = [] }
            }
        }
    }

    // MARK: - Feed hide handling

    private func observeFeedHideNotifications() {
        hideObserverTasks.append(Task { [weak self] in
            for await note in NotificationCenter.default.notifications(named: .hideVideoFromFeed) {
                guard let self, let videoId = note.userInfo?["videoId"] as? String else { continue }
                self.results.removeAll { $0.id == videoId }
            }
        })
        hideObserverTasks.append(Task { [weak self] in
            for await note in NotificationCenter.default.notifications(named: .hideChannelFromFeed) {
                guard let self, let channelId = note.userInfo?["channelId"] as? String else { continue }
                self.results.removeAll { $0.channelId == channelId }
            }
        })
    }
}

// MARK: - ChannelViewModel

@MainActor
@Observable
public final class ChannelViewModel {

    public private(set) var channel: Channel?
    public private(set) var videos: [Video] = []
    public private(set) var isLoading: Bool = false
    public var error: Error?

    private let api: any InnerTubeAPIProtocol
    private var nextPageToken: String?
    private var publicationTask: Task<Void, Never>?
    private var hideObserverTasks: [Task<Void, Never>] = []

    public init(api: any InnerTubeAPIProtocol = InnerTubeAPI()) {
        self.api = api
        observeFeedHideNotifications()
    }

    public func load(channelId: String) {
        Task { await loadAsync(channelId: channelId) }
    }

    private func loadAsync(channelId: String) async {
        error = nil
        isLoading = true
        defer { isLoading = false }
        do {
            let (ch, group) = try await api.fetchChannel(channelId: channelId)
            channel = ch
            videos = VideoPublicationSortPolicy.sorted(group.videos, for: .channel)
            nextPageToken = group.nextPageToken
            schedulePublicationEnrichment()
        } catch {
            self.error = error
        }
    }

    public func loadMore() {
        guard let id = channel?.id, let token = nextPageToken, !isLoading else { return }
        Task {
            error = nil
            isLoading = true
            defer { isLoading = false }
            do {
                let group = try await retryWithBackoff(label: "ChannelVM") {
                    try await api.fetchChannelVideos(channelId: id, continuationToken: token)
                }
                videos = VideoPublicationSortPolicy.merging(
                    existing: videos,
                    page: group.videos,
                    for: .channel
                )
                nextPageToken = group.nextPageToken
                schedulePublicationEnrichment()
            } catch {
                self.error = error
            }
        }
    }

    private func schedulePublicationEnrichment() {
        publicationTask?.cancel()
        let snapshot = videos
        let expectedIDs = snapshot.map(\.id)
        publicationTask = Task { [weak self, api] in
            let enriched = await VideoPublicationDateEnricher.shared.enrich(snapshot) { id in
                try? await api.fetchExactPublicationDate(videoId: id)
            }
            guard let self, !Task.isCancelled, self.videos.map(\.id) == expectedIDs else { return }
            self.videos = VideoPublicationSortPolicy.sorted(enriched, for: .channel)
        }
    }

    // MARK: - Feed hide handling

    private func observeFeedHideNotifications() {
        hideObserverTasks.append(Task { [weak self] in
            for await note in NotificationCenter.default.notifications(named: .hideVideoFromFeed) {
                guard let self, let videoId = note.userInfo?["videoId"] as? String else { continue }
                self.videos.removeAll { $0.id == videoId }
            }
        })
        hideObserverTasks.append(Task { [weak self] in
            for await note in NotificationCenter.default.notifications(named: .hideChannelFromFeed) {
                guard let self, let channelId = note.userInfo?["channelId"] as? String else { continue }
                self.videos.removeAll { $0.channelId == channelId }
            }
        })
    }
}
