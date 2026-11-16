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
/// - a stale feed refreshes itself when the user returns;
/// - filters (the Russian-only policy) run before a page is committed, so
///   the visible list changes exactly once per refresh or appended page.
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
    private var admission: FeedAdmission = .all
    private let api: any InnerTubeAPIProtocol

    /// A first page shorter than this (after filtering) pulls continuation
    /// pages before it is shown, up to `maxFillPages`.
    nonisolated static let minimumFirstPage = 8
    nonisolated static let maxFillPages = 3

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

    /// Sets the admission policy. A different policy reloads a loaded feed.
    public func setAdmission(_ newAdmission: FeedAdmission) {
        guard newAdmission.key != admission.key else { return }
        admission = newAdmission
        if loadedAt != nil || isLoading { load() }
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
        let admission = admission
        loadTask = Task { [weak self] in
            let result = await Self.fetchFirstPage(chip: chip, api: api, admission: admission)
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
        let admission = admission
        let known = Set(videos.map(\.id))
        moreTask = Task { [weak self] in
            let page = await Self.fetchContinuation(token: token, known: known, api: api, admission: admission)
            guard let self, !Task.isCancelled, gen == self.generation else { return }
            self.isLoadingMore = false
            guard let page else { return }
            var seen = Set(self.videos.map(\.id))
            self.videos += page.videos.filter { seen.insert($0.id).inserted }
            self.nextPageToken = page.nextPageToken
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
        api: any InnerTubeAPIProtocol,
        admission: FeedAdmission
    ) async -> Result<Page, Error> {
        let raw: Page
        do {
            switch chip {
            case .all: raw = flatten(try await api.fetchHomeRows(continuationToken: nil))
            case .music: raw = page(try await api.fetchMusic())
            case .gaming: raw = page(try await api.fetchGaming())
            case .news: raw = page(try await api.fetchNews())
            case .live: raw = page(try await api.fetchLive())
            case .sports: raw = page(try await api.fetchSports())
            }
        } catch {
            return .failure(error)
        }
        var result = Page(videos: await admission.admit(raw.videos), nextPageToken: raw.nextPageToken)
        // Fill a heavily filtered first page before showing it, so the
        // refresh lands as one complete screen.
        var fills = 0
        while chip == .all, admission.key != FeedAdmission.all.key, fills < maxFillPages, let token = result.nextPageToken,
              result.videos.filter({ !$0.isShort }).count < minimumFirstPage, !Task.isCancelled {
            fills += 1
            guard let more = await fetchContinuation(
                token: token, known: Set(result.videos.map(\.id)), api: api, admission: admission, maxPages: 1
            ) else { break }
            result.videos += more.videos
            result.nextPageToken = more.nextPageToken
        }
        return .success(result)
    }

    /// Fetches continuation pages until one yields an admitted new video
    /// (or `maxPages` is reached). Nil means the request failed.
    private nonisolated static func fetchContinuation(
        token: String,
        known: Set<String>,
        api: any InnerTubeAPIProtocol,
        admission: FeedAdmission,
        maxPages: Int = maxFillPages
    ) async -> Page? {
        var token: String? = token
        var seen = known
        var collected: [Video] = []
        var pages = 0
        while let current = token, pages < maxPages, !Task.isCancelled {
            pages += 1
            guard let rows = try? await api.fetchHomeRows(continuationToken: current) else {
                return collected.isEmpty ? nil : Page(videos: collected, nextPageToken: current)
            }
            let page = flatten(rows)
            let fresh = page.videos.filter { seen.insert($0.id).inserted }
            collected += await admission.admit(fresh)
            // A page with the same cursor ends the feed.
            token = page.nextPageToken == current ? nil : page.nextPageToken
            if !collected.isEmpty { break }
        }
        return Page(videos: collected, nextPageToken: token)
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
