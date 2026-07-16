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
    public private(set) var results: [Video] = []
    public private(set) var suggestions: [String] = []
    public private(set) var history: [SearchHistoryEntry] = []
    public private(set) var isLoading: Bool = false
    public var error: Error?

    private let api: any InnerTubeAPIProtocol
    private let historyStore: SearchHistoryStore
    private var nextPageToken: String?
    private var searchTask: Task<Void, Never>?
    private var publicationTask: Task<Void, Never>?
    private var suggestTask: Task<Void, Never>?
    private var hideObserverTasks: [Task<Void, Never>] = []

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
        guard !trimmed.isEmpty else { return }
        results = []
        nextPageToken = nil
        searchTask?.cancel()
        publicationTask?.cancel()
        searchTask = Task { await performSearch(query: trimmed, filter: filter) }
        Task { await recordSearch(trimmed) }
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
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        results = []
        nextPageToken = nil
        searchTask?.cancel()
        publicationTask?.cancel()
        searchTask = Task { await performSearch(query: query, filter: filter) }
    }

    public func loadMore() {
        guard let token = nextPageToken, !isLoading else { return }
        searchTask = Task { await performSearch(query: query, continuationToken: token, filter: filter) }
    }

    private func performSearch(query: String, continuationToken: String? = nil, filter: SearchFilter = .default) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let group = try await retryWithBackoff(label: "SearchVM") {
                try await api.search(query: query, continuationToken: continuationToken, filter: filter)
            }
            if continuationToken == nil {
                results = VideoPublicationSortPolicy.sorted(group.videos, for: .search)
            } else {
                results = VideoPublicationSortPolicy.merging(
                    existing: results,
                    page: group.videos,
                    for: .search
                )
            }
            nextPageToken = group.nextPageToken
            schedulePublicationEnrichment()
        } catch {
            if !Task.isCancelled { self.error = error }
        }
    }

    private func schedulePublicationEnrichment() {
        publicationTask?.cancel()
        let snapshot = results
        let expectedIDs = snapshot.map(\.id)
        publicationTask = Task { [weak self, api] in
            let enriched = await VideoPublicationDateEnricher.shared.enrich(snapshot) { id in
                try? await api.fetchExactPublicationDate(videoId: id)
            }
            guard let self, !Task.isCancelled, self.results.map(\.id) == expectedIDs else { return }
            self.results = VideoPublicationSortPolicy.sorted(enriched, for: .search)
        }
    }

    private func fetchSuggestions(for query: String) {
        print("[Suggestions] fetchSuggestions spawning task for q='\(query)'")
        suggestTask?.cancel()
        suggestTask = Task {
            do {
                let s = try await api.fetchSearchSuggestions(query: query)
                guard !Task.isCancelled else {
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
