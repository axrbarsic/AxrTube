import Foundation

// MARK: - RSSFeedStore
//
// Persists user-added RSS feed subscriptions on-device in UserDefaults as JSON.
// Follows the same actor pattern as LocalSubscriptionStore.
// Thread-safe: implemented as a Swift actor.

public actor RSSFeedStore {

    // MARK: - Singleton

    public static let shared = RSSFeedStore()

    // MARK: - Storage key

    private static let udKey = "st_rss_feeds"

    // MARK: - State

    private var feeds: [UUID: RSSFeedInfo] = [:]
    private let defaults: UserDefaults

    // MARK: - Init

    private init() {
        self.defaults = .standard
        if let data = UserDefaults.standard.data(forKey: Self.udKey),
           let decoded = try? JSONDecoder().decode([String: RSSFeedInfo].self, from: data) {
            feeds = Dictionary(uniqueKeysWithValues: decoded.compactMap { k, v in
                UUID(uuidString: k).map { ($0, v) }
            })
        }
    }

    /// Designated initializer for unit testing.
    /// Pass a unique `suiteName` string to get a fully isolated store.
    init(suiteName: String) {
        let ud = UserDefaults(suiteName: suiteName) ?? .standard
        self.defaults = ud
        if let data = ud.data(forKey: Self.udKey),
           let decoded = try? JSONDecoder().decode([String: RSSFeedInfo].self, from: data) {
            feeds = Dictionary(uniqueKeysWithValues: decoded.compactMap { k, v in
                UUID(uuidString: k).map { ($0, v) }
            })
        }
    }

    // MARK: - Public API

    /// Returns all saved feeds sorted by `addedAt` descending (newest first).
    public func allFeeds() -> [RSSFeedInfo] {
        feeds.values.sorted { $0.addedAt > $1.addedAt }
    }

    /// Adds a new feed. Idempotent by URL — if the same feedURL already exists, no-op.
    public func addFeed(_ feed: RSSFeedInfo) {
        guard !feeds.values.contains(where: { $0.feedURL == feed.feedURL }) else { return }
        feeds[feed.id] = feed
        persist()
    }

    /// Removes a feed by ID. No-op if not found.
    public func removeFeed(id: UUID) {
        feeds.removeValue(forKey: id)
        persist()
    }

    /// Toggles the `isActive` flag for a feed by ID.
    public func setActive(_ id: UUID, _ active: Bool) {
        feeds[id]?.isActive = active
        persist()
    }

    /// Updates the title for a feed by ID.
    public func updateTitle(_ id: UUID, title: String) {
        feeds[id]?.title = title
        persist()
    }

    // MARK: - Persistence

    private func persist() {
        let dict = Dictionary(uniqueKeysWithValues: feeds.map { ($0.key.uuidString, $0.value) })
        if let data = try? JSONEncoder().encode(dict) {
            defaults.set(data, forKey: Self.udKey)
        }
        let value = dict
        Task { await iCloudSyncManager.shared.push(.rssFeeds, value) }
    }
}
