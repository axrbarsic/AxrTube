import Foundation
import iPocketTubeCore

// MARK: - RSSFeedsViewModel

/// Fetches and merges videos from all active RSS feed subscriptions.
/// Deduplicates by video ID and sorts newest-first.

@MainActor
@Observable
public final class RSSFeedsViewModel {

    // MARK: - State

    public private(set) var videos: [Video] = []
    public private(set) var isLoading = false
    public var error: Error?
    private var loadGeneration: UInt = 0
    private var activeLoadTask: Task<Void, Never>?

    // MARK: - Dependencies

    private let feedStore: RSSFeedStore
    private let session: URLSession

    // MARK: - Init

    public init(feedStore: RSSFeedStore = .shared, session: URLSession = .shared) {
        self.feedStore = feedStore
        self.session = session
    }

    // MARK: - Load

    public func load() {
        // Re-entrancy guard: .task, .refreshable and sheet dismissal may all
        // call load(); a generation token lets the newest call win and cancels
        // any in-flight fetch instead of stacking duplicate network traffic.
        loadGeneration &+= 1
        let generation = loadGeneration
        activeLoadTask?.cancel()
        isLoading = true
        activeLoadTask = Task { [weak self] in
            guard let self else { return }
            await self.fetchAll(generation: generation)
            guard generation == self.loadGeneration else { return }
            self.isLoading = false
        }
    }

    private func fetchAll(generation: UInt) async {
        let activeFeeds = await feedStore.allFeeds().filter { $0.isActive }
        guard !activeFeeds.isEmpty else {
            videos = []
            return
        }

        let sessionCopy = session
        var allVideos: [Video] = []

        await withTaskGroup(of: [Video].self) { group in
            for feed in activeFeeds {
                let feedURL = feed.feedURL
                let channelId = RSSFeedInfo.channelId(from: feedURL) ?? "unknown"
                group.addTask {
                    guard let (data, response) = try? await sessionCopy.data(from: feedURL),
                          let http = response as? HTTPURLResponse,
                          (200..<300).contains(http.statusCode) else { return [] }
                    return parseYouTubeRSS(data, channelId: channelId).videos
                }
            }
            for await feedVideos in group {
                guard !Task.isCancelled else { return }
                allVideos.append(contentsOf: feedVideos)
            }
        }

        guard generation == loadGeneration else { return }
        var seen = Set<String>()
        let deduplicated = allVideos.filter { seen.insert($0.id).inserted }
        videos = VideoPublicationSortPolicy.sorted(deduplicated, for: .rss)
    }

    public func removeFeed(id: UUID) {
        Task {
            await feedStore.removeFeed(id: id)
            await fetchAll(generation: loadGeneration)
        }
    }
}
