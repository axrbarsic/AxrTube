import Foundation
import Testing
@testable import iPocketTubeCore

// MARK: - TTLCacheTests
//
// Covers the generic TTL/eviction logic shared by HLSManifestCache and
// LocalSubscriptionFeedCache — see arch-plan-3-generic-ttl-cache.md.

@Suite("TTLCache")
struct TTLCacheTests {

    /// Mutable clock so tests can advance time deterministically.
    final class Clock {
        var now: Date
        init(_ now: Date = Date(timeIntervalSince1970: 0)) { self.now = now }
        func advance(_ seconds: TimeInterval) { now.addTimeInterval(seconds) }
    }

    @Test("set then get returns the stored value")
    func setThenGetReturnsValue() {
        var cache = TTLCache<String, Int>(ttl: 60)
        cache.set(42, for: "a")
        #expect(cache.get("a") == 42)
    }

    @Test("get returns nil for a missing key")
    func getMissingKeyReturnsNil() {
        var cache = TTLCache<String, Int>(ttl: 60)
        #expect(cache.get("missing") == nil)
    }

    @Test("entry within TTL is returned")
    func entryWithinTTLIsReturned() {
        let clock = Clock()
        var cache = TTLCache<String, Int>(ttl: 60, now: { clock.now })
        cache.set(1, for: "a")
        clock.advance(59)
        #expect(cache.get("a") == 1)
    }

    @Test("entry past TTL is treated as missing")
    func entryPastTTLIsMissing() {
        let clock = Clock()
        var cache = TTLCache<String, Int>(ttl: 60, now: { clock.now })
        cache.set(1, for: "a")
        clock.advance(61)
        #expect(cache.get("a") == nil)
    }

    @Test("expired entry is removed so it can be re-stored fresh")
    func expiredEntryIsRemovedAndCanBeReSet() {
        let clock = Clock()
        var cache = TTLCache<String, Int>(ttl: 60, maxEntries: 1, now: { clock.now })
        cache.set(1, for: "a")
        clock.advance(61)
        #expect(cache.get("a") == nil)
        cache.set(2, for: "a")
        #expect(cache.get("a") == 2)
    }

    @Test("maxEntries evicts the oldest entry by storedAt")
    func maxEntriesEvictsOldest() {
        let clock = Clock()
        var cache = TTLCache<String, Int>(ttl: 3600, maxEntries: 2, now: { clock.now })
        cache.set(1, for: "a")
        clock.advance(1)
        cache.set(2, for: "b")
        clock.advance(1)
        cache.set(3, for: "c") // should evict "a", the oldest
        #expect(cache.get("a") == nil)
        #expect(cache.get("b") == 2)
        #expect(cache.get("c") == 3)
    }

    @Test("updating an existing key at capacity does not evict")
    func updatingExistingKeyAtCapacityDoesNotEvict() {
        let clock = Clock()
        var cache = TTLCache<String, Int>(ttl: 3600, maxEntries: 2, now: { clock.now })
        cache.set(1, for: "a")
        clock.advance(1)
        cache.set(2, for: "b")
        clock.advance(1)
        cache.set(99, for: "a") // update, not insert — "b" should survive
        #expect(cache.get("a") == 99)
        #expect(cache.get("b") == 2)
    }

    @Test("invalidate removes a specific key")
    func invalidateRemovesKey() {
        var cache = TTLCache<String, Int>(ttl: 60)
        cache.set(1, for: "a")
        cache.set(2, for: "b")
        cache.invalidate("a")
        #expect(cache.get("a") == nil)
        #expect(cache.get("b") == 2)
    }

    @Test("invalidateAll clears every entry")
    func invalidateAllClearsEverything() {
        var cache = TTLCache<String, Int>(ttl: 60)
        cache.set(1, for: "a")
        cache.set(2, for: "b")
        cache.invalidateAll()
        #expect(cache.get("a") == nil)
        #expect(cache.get("b") == nil)
    }

    @Test("cache without maxEntries grows unbounded")
    func noMaxEntriesGrowsUnbounded() {
        var cache = TTLCache<Int, Int>(ttl: 3600)
        for i in 0..<100 {
            cache.set(i, for: i)
        }
        for i in 0..<100 {
            #expect(cache.get(i) == i)
        }
    }
}
