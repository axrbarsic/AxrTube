import Foundation

// MARK: - TTLCache
//
// Generic in-memory TTL cache with optional LRU-by-age eviction. Used by
// HLSManifestCache and LocalSubscriptionFeedCache to share the
// expiry/eviction logic that was previously duplicated between them
// — see arch-plan-3-generic-ttl-cache.md.

/// Generic in-memory TTL cache with optional LRU-by-age eviction.
/// Plain value type, not thread-safe by itself — callers provide
/// whatever isolation they need (see HLSManifestCache / LocalSubscriptionFeedCache).
public struct TTLCache<Key: Hashable, Value> {
    private struct Entry {
        let value: Value
        let storedAt: Date
    }

    private var store: [Key: Entry] = [:]
    private let ttl: TimeInterval
    private let maxEntries: Int?
    private let now: () -> Date

    /// - Parameters:
    ///   - ttl: entries older than this are treated as missing.
    ///   - maxEntries: if set, `set()` evicts the oldest entry (by `storedAt`)
    ///     once the cache would exceed this size.
    ///   - now: clock injection point for deterministic tests.
    public init(ttl: TimeInterval, maxEntries: Int? = nil, now: @escaping () -> Date = Date.init) {
        self.ttl = ttl
        self.maxEntries = maxEntries
        self.now = now
    }

    /// Returns the cached value for `key` if present and within TTL.
    /// Expired entries are removed as a side effect.
    public mutating func get(_ key: Key) -> Value? {
        guard let entry = store[key] else { return nil }
        guard now().timeIntervalSince(entry.storedAt) < ttl else {
            store.removeValue(forKey: key)
            return nil
        }
        return entry.value
    }

    /// Stores `value` for `key`, stamped with the current time. Evicts the
    /// oldest entry first if `maxEntries` would be exceeded.
    public mutating func set(_ value: Value, for key: Key) {
        if let maxEntries, store.count >= maxEntries, store[key] == nil,
           let oldest = store.min(by: { $0.value.storedAt < $1.value.storedAt }) {
            store.removeValue(forKey: oldest.key)
        }
        store[key] = Entry(value: value, storedAt: now())
    }

    public mutating func invalidate(_ key: Key) {
        store.removeValue(forKey: key)
    }

    public mutating func invalidateAll() {
        store.removeAll()
    }
}
