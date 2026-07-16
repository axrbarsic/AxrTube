import Foundation

// MARK: - HLS Manifest Cache

/// In-memory per-video-ID cache for HLS variant URL maps.
///
/// Populated by `PlaybackQualityManager` after each `fetchHLSVariantURLs` call and
/// consulted before making the network request on subsequent loads of the same video.
/// Survives video-to-video navigation (unlike `hlsVariantURLs` on the manager, which
/// is cleared on `reset()`). This eliminates the ~8 s manifest fetch when a user
/// revisits a video during the same app session.
///
/// - TTL: 30 minutes — YouTube CDN tokens typically live hours; `invalidate(for:)` handles 403s on retry.
/// - Capacity: 30 entries — matches `VideoPreloadCache` LRU limit; eviction is
///   oldest-first by `fetchedAt` date.
public struct HLSManifestCache {

    // MARK: - Shared instance

    /// The shared singleton. Access is compiler-enforced to `@MainActor` at every call site.
    /// All callers (`PlaybackQualityManager`, `PlaybackViewModel`) are already `@MainActor`.
    @MainActor public static var shared = HLSManifestCache()

    // MARK: - Configuration

    public static let ttl: TimeInterval = 30 * 60
    public static let maxEntries = 30

    // MARK: - Storage

    private var cache = TTLCache<String, [Int: URL]>(ttl: HLSManifestCache.ttl, maxEntries: HLSManifestCache.maxEntries)

    // MARK: - Interface

    /// Returns cached variant URLs for `videoId` if the entry exists and is within the TTL.
    public mutating func variants(for videoId: String) -> [Int: URL]? {
        cache.get(videoId)
    }

    /// Stores variant URLs for `videoId`. Evicts the oldest entry when at capacity.
    public mutating func store(_ variants: [Int: URL], for videoId: String) {
        cache.set(variants, for: videoId)
    }

    /// Removes a specific video's cache entry (e.g. after a 403 to force a fresh fetch).
    public mutating func invalidate(for videoId: String) {
        cache.invalidate(videoId)
    }
}
