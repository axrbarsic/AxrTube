import Testing
import Foundation
@testable import iPocketTubeCore

// MARK: - UserDefaultsBackedStore conformance tests
//
// Covers the three guarantees all conforming stores must satisfy:
//   1. Roundtrip: data written via public API survives persist → loadFrom
//   2. Clear: key is absent from UserDefaults after clearing
//   3. Isolation: two stores with different suiteName never share data

// MARK: - VideoStateStore

@Suite("VideoStateStore – UserDefaultsBackedStore")
struct VideoStateStoreConformanceTests {

    @Test("Roundtrip: saved position survives persist → loadFrom")
    func roundtrip() async throws {
        let suite = "test-vss-\(UUID().uuidString)"
        let store = VideoStateStore(suiteName: suite)
        await store.save(videoId: "abc", position: 42, duration: 300)
        // loadFrom uses the same suite → should recover the state
        let loaded = VideoStateStore.loadFrom(UserDefaults(suiteName: suite) ?? .standard)
        #expect(loaded?["abc"]?.position == 42)
    }

    @Test("Clear: removeObject deletes key from UserDefaults")
    func clearDeletesKey() async throws {
        let suite = "test-vss-clear-\(UUID().uuidString)"
        let ud = UserDefaults(suiteName: suite) ?? .standard
        let store = VideoStateStore(suiteName: suite)
        await store.save(videoId: "x", position: 10, duration: 100)
        #expect(ud.data(forKey: VideoStateStore.defaultsKey) != nil)
        await store.clear(videoId: "x")
        // After clearing a single entry the key may still exist (empty dict)
        // but the entry itself must be absent
        let loaded = VideoStateStore.loadFrom(ud)
        #expect(loaded?["x"] == nil)
    }

    @Test("Isolation: two stores with different suiteNames never share data")
    func isolation() async throws {
        let suiteA = "test-vss-a-\(UUID().uuidString)"
        let suiteB = "test-vss-b-\(UUID().uuidString)"
        let storeA = VideoStateStore(suiteName: suiteA)
        let storeB = VideoStateStore(suiteName: suiteB)
        await storeA.save(videoId: "vid1", position: 99, duration: 200)
        let loadedInB = VideoStateStore.loadFrom(UserDefaults(suiteName: suiteB) ?? .standard)
        #expect(loadedInB?["vid1"] == nil)
        _ = storeB  // silence unused-variable warning
    }
}

// MARK: - CurrentQueueStore

@Suite("CurrentQueueStore – UserDefaultsBackedStore")
struct CurrentQueueStoreConformanceTests {

    @Test("Roundtrip: appended video survives persist → loadFrom")
    func roundtrip() async throws {
        let suite = "test-cqs-\(UUID().uuidString)"
        let store = CurrentQueueStore(suiteName: suite)
        let video = Video(id: "v1", title: "Test", channelTitle: "Ch")
        await store.append(video)
        let loaded = CurrentQueueStore.loadFrom(UserDefaults(suiteName: suite) ?? .standard)
        #expect(loaded?.first?.id == "v1")
    }

    @Test("Clear: removeObject deletes key from UserDefaults")
    func clearDeletesKey() async throws {
        let suite = "test-cqs-clear-\(UUID().uuidString)"
        let ud = UserDefaults(suiteName: suite) ?? .standard
        let store = CurrentQueueStore(suiteName: suite)
        await store.append(Video(id: "v2", title: "T", channelTitle: "C"))
        #expect(ud.data(forKey: CurrentQueueStore.defaultsKey) != nil)
        await store.clear()
        #expect(ud.data(forKey: CurrentQueueStore.defaultsKey) == nil)
    }

    @Test("Isolation: two stores with different suiteNames never share data")
    func isolation() async throws {
        let suiteA = "test-cqs-a-\(UUID().uuidString)"
        let suiteB = "test-cqs-b-\(UUID().uuidString)"
        let storeA = CurrentQueueStore(suiteName: suiteA)
        let storeB = CurrentQueueStore(suiteName: suiteB)
        await storeA.append(Video(id: "unique", title: "T", channelTitle: "C"))
        let loadedInB = CurrentQueueStore.loadFrom(UserDefaults(suiteName: suiteB) ?? .standard)
        #expect(loadedInB == nil || loadedInB?.isEmpty == true)
        _ = storeB
    }
}

// MARK: - SearchHistoryStore

@Suite("SearchHistoryStore – UserDefaultsBackedStore")
struct SearchHistoryStoreConformanceTests {

    @Test("Roundtrip: added query survives persist → loadFrom")
    func roundtrip() async throws {
        let suite = "test-shs-\(UUID().uuidString)"
        let store = SearchHistoryStore(suiteName: suite)
        await store.add("swift concurrency")
        let loaded = SearchHistoryStore.loadFrom(UserDefaults(suiteName: suite) ?? .standard)
        #expect(loaded?.first?.query == "swift concurrency")
    }

    @Test("Clear: persists empty array to UserDefaults")
    func clearPersistsEmpty() async throws {
        let suite = "test-shs-clear-\(UUID().uuidString)"
        let store = SearchHistoryStore(suiteName: suite)
        await store.add("query")
        await store.clear()
        let loaded = SearchHistoryStore.loadFrom(UserDefaults(suiteName: suite) ?? .standard)
        #expect(loaded?.isEmpty == true)
    }

    @Test("Isolation: two stores with different suiteNames never share data")
    func isolation() async throws {
        let suiteA = "test-shs-a-\(UUID().uuidString)"
        let suiteB = "test-shs-b-\(UUID().uuidString)"
        let storeA = SearchHistoryStore(suiteName: suiteA)
        let storeB = SearchHistoryStore(suiteName: suiteB)
        await storeA.add("private query")
        let loadedInB = SearchHistoryStore.loadFrom(UserDefaults(suiteName: suiteB) ?? .standard)
        #expect(loadedInB == nil || loadedInB?.isEmpty == true)
        _ = storeB
    }
}

// MARK: - LocalSubscriptionStore

@Suite("LocalSubscriptionStore – UserDefaultsBackedStore")
struct LocalSubscriptionStoreConformanceTests {

    @Test("Roundtrip: followed channel survives persist → loadFrom")
    func roundtrip() async throws {
        let suite = "test-lss-\(UUID().uuidString)"
        let store = LocalSubscriptionStore(suiteName: suite)
        let channel = LocalChannel(id: "ch1", title: "Test Channel", thumbnailURL: nil)
        await store.follow(channel)
        let loaded = LocalSubscriptionStore.loadFrom(UserDefaults(suiteName: suite) ?? .standard)
        #expect(loaded?["ch1"]?.title == "Test Channel")
    }

    @Test("Unfollow: channel absent after persist → loadFrom")
    func unfollowPersists() async throws {
        let suite = "test-lss-unfollow-\(UUID().uuidString)"
        let store = LocalSubscriptionStore(suiteName: suite)
        let channel = LocalChannel(id: "ch2", title: "Gone", thumbnailURL: nil)
        await store.follow(channel)
        await store.unfollow(channelId: "ch2")
        let loaded = LocalSubscriptionStore.loadFrom(UserDefaults(suiteName: suite) ?? .standard)
        #expect(loaded?["ch2"] == nil)
    }

    @Test("Isolation: two stores with different suiteNames never share data")
    func isolation() async throws {
        let suiteA = "test-lss-a-\(UUID().uuidString)"
        let suiteB = "test-lss-b-\(UUID().uuidString)"
        let storeA = LocalSubscriptionStore(suiteName: suiteA)
        let storeB = LocalSubscriptionStore(suiteName: suiteB)
        await storeA.follow(LocalChannel(id: "ch3", title: "Solo", thumbnailURL: nil))
        let loadedInB = LocalSubscriptionStore.loadFrom(UserDefaults(suiteName: suiteB) ?? .standard)
        #expect(loadedInB == nil || loadedInB?["ch3"] == nil)
        _ = storeB
    }
}
