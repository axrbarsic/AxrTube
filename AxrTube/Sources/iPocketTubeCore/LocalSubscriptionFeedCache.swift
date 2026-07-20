import Foundation

// MARK: - LocalSubscriptionFeedCache
//
// Per-channel TTL cache for local subscription feed videos.
// Prevents redundant RSS fetches when the user navigates away and back.
// Mirrors VideoPreloadCache's entry / TTL structure.
// Thread-safe: Swift actor.

public actor LocalSubscriptionFeedCache {

    // MARK: - Singleton

    public static let shared = LocalSubscriptionFeedCache()

    // MARK: - TTL

    /// Cache lifetime — matches FreeTube's implicit refresh behaviour.
    static let ttl: TimeInterval = 15 * 60   // 15 minutes

    // MARK: - State

    private var cache = TTLCache<String, [Video]>(ttl: LocalSubscriptionFeedCache.ttl)

    public init() {}

    // MARK: - Public API

    /// Returns cached videos for `channelId` if still within TTL; nil if stale or missing.
    public func videos(for channelId: String) -> [Video]? {
        cache.get(channelId)
    }

    /// Stores a fetch result for `channelId`, stamped with the current time.
    public func store(videos: [Video], for channelId: String) {
        cache.set(videos, for: channelId)
    }

    /// Removes the cached entry for `channelId` (e.g. after unfollow).
    public func invalidate(channelId: String) {
        cache.invalidate(channelId)
    }

    /// Clears all cached entries. Call on manual pull-to-refresh.
    public func invalidateAll() {
        cache.invalidateAll()
    }
}
