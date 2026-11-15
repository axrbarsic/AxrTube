import Foundation
import Observation

/// A topic chip on the Home feed. "Все" is the personalised Home; the others
/// are real YouTube destination feeds, not locally invented categories.
public enum YouTubeHomeChip: String, CaseIterable, Identifiable, Sendable {
    case all, music, gaming, news, live, sports

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .all: "Все"
        case .music: "Музыка"
        case .gaming: "Видеоигры"
        case .news: "Новости"
        case .live: "Трансляции"
        case .sports: "Спорт"
        }
    }
}

/// Home feed with YouTube iOS refresh semantics:
/// - pull-to-refresh (or re-tapping the Home tab) requests Home without a
///   continuation and replaces the whole feed with the response, in service
///   order, dropping previously appended pages;
/// - a failed refresh keeps the visible feed and reports the error;
/// - a stale feed refreshes itself when the user returns.
@MainActor
@Observable
public final class YouTubeHomeFeedModel {
    public private(set) var videos: [Video] = []
    public private(set) var chip: YouTubeHomeChip = .all
    public private(set) var isLoading = false
    public private(set) var isLoadingMore = false
    public private(set) var errorMessage: String?
    public private(set) var loadedAt: Date?
    /// Bumped on every committed replacement so the view can scroll to top.
    public private(set) var replacementID = 0

    private var nextPageToken: String?
    private var generation = 0
    private var loadTask: Task<Void, Never>?
    private var moreTask: Task<Void, Never>?
    private var hasAuth = false
    private var authGeneration: UInt64?
    private let api: any InnerTubeAPIProtocol

    public init(api: any InnerTubeAPIProtocol) {
        self.api = api
    }

    public var hasMore: Bool { nextPageToken != nil }

    /// Regular videos in service order.
    public var regularVideos: [Video] { videos.filter { !$0.isShort } }
    /// Shorts returned inside Home, shown as YouTube's Shorts shelf.
    public var shorts: [Video] { videos.filter(\.isShort) }

    // MARK: Auth

    public func applyAuthSnapshot(_ snapshot: AuthSessionSnapshot) async {
        if let current = authGeneration, snapshot.generation <= current { return }
        authGeneration = snapshot.generation
        let signedIn = snapshot.accessToken != nil
        let changed = signedIn != hasAuth
        hasAuth = signedIn
        if changed { clear() }
        await api.applyAuthSnapshot(snapshot)
        if changed || loadedAt == nil { load() }
    }

    // MARK: Loading

    public func select(_ newChip: YouTubeHomeChip) {
        guard newChip != chip else { return }
        chip = newChip
        clear()
        load()
    }

    /// Starts a fresh first page. Keeps the current feed visible until the
    /// response arrives, then replaces it atomically.
    public func load() {
        generation &+= 1
        let gen = generation
        loadTask?.cancel()
        moreTask?.cancel()
        isLoadingMore = false
        isLoading = true
        let chip = chip
        let api = api
        loadTask = Task { [weak self] in
            let result = await Self.fetchFirstPage(chip: chip, api: api)
            guard let self, !Task.isCancelled, gen == self.generation else { return }
            self.isLoading = false
            switch result {
            case .success(let page):
                self.videos = Self.unique(page.videos)
                self.nextPageToken = page.nextPageToken
                self.errorMessage = nil
                self.loadedAt = Date()
                self.replacementID &+= 1
            case .failure:
                self.errorMessage = self.videos.isEmpty
                    ? "Не удалось загрузить ленту. Проверьте подключение."
                    : "Нет подключения к сети"
            }
        }
    }

    /// Pull-to-refresh: awaits the replacement so the system spinner stays up.
    public func refresh() async {
        load()
        await loadTask?.value
    }

    public func refreshIfStale(threshold: TimeInterval = 30 * 60, now: Date = Date()) {
        guard !isLoading else { return }
        guard let loadedAt else { load(); return }
        if now.timeIntervalSince(loadedAt) > threshold { load() }
    }

    public func loadMore() {
        guard let token = nextPageToken, !isLoadingMore, !isLoading, chip == .all else { return }
        isLoadingMore = true
        let gen = generation
        let api = api
        moreTask = Task { [weak self] in
            let rows = try? await api.fetchHomeRows(continuationToken: token)
            guard let self, !Task.isCancelled, gen == self.generation else { return }
            self.isLoadingMore = false
            guard let rows else { return }
            let page = Self.flatten(rows)
            var seen = Set(self.videos.map(\.id))
            self.videos += page.videos.filter { !$0.id.isEmpty && seen.insert($0.id).inserted }
            // A page with nothing new and no further cursor ends the feed.
            self.nextPageToken = page.nextPageToken == token ? nil : page.nextPageToken
        }
    }

    public func remove(videoID: String) {
        videos.removeAll { $0.id == videoID }
    }

    private func clear() {
        generation &+= 1
        loadTask?.cancel()
        moreTask?.cancel()
        videos = []
        nextPageToken = nil
        loadedAt = nil
        errorMessage = nil
        isLoading = false
        isLoadingMore = false
    }

    // MARK: Fetching

    private struct Page: Sendable {
        var videos: [Video]
        var nextPageToken: String?
    }

    private nonisolated static func fetchFirstPage(
        chip: YouTubeHomeChip,
        api: any InnerTubeAPIProtocol
    ) async -> Result<Page, Error> {
        do {
            switch chip {
            case .all: return .success(flatten(try await api.fetchHomeRows(continuationToken: nil)))
            case .music: return .success(page(try await api.fetchMusic()))
            case .gaming: return .success(page(try await api.fetchGaming()))
            case .news: return .success(page(try await api.fetchNews()))
            case .live: return .success(page(try await api.fetchLive()))
            case .sports: return .success(page(try await api.fetchSports()))
            }
        } catch {
            return .failure(error)
        }
    }

    private nonisolated static func page(_ group: VideoGroup) -> Page {
        Page(videos: group.videos, nextPageToken: nil)
    }

    private nonisolated static func flatten(_ rows: [VideoGroup]) -> Page {
        Page(
            videos: unique(rows.flatMap(\.videos)),
            nextPageToken: rows.last(where: { $0.nextPageToken != nil })?.nextPageToken
        )
    }

    private nonisolated static func unique(_ videos: [Video]) -> [Video] {
        var seen = Set<String>()
        return videos.filter { !$0.id.isEmpty && seen.insert($0.id).inserted }
    }
}
