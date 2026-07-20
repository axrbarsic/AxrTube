import Foundation
import Testing
@testable import iPocketTubeCore

// MARK: - SearchHistoryStoreTests
//
// Uses an isolated UserDefaults suite per test to avoid cross-test pollution.
// Mirrors CurrentQueueStoreTests / VideoStateStoreTests patterns.

@Suite("Search History Store")
struct SearchHistoryStoreTests {

    // MARK: - Helpers

    private func makeStore() -> SearchHistoryStore {
        SearchHistoryStore(suiteName: "test-\(UUID().uuidString)")
    }

    // MARK: - Add

    @Test("Adding a query saves it to the store")
    func addSavesEntry() async {
        let store = makeStore()
        await store.add("swift concurrency")
        let entries = await store.all
        #expect(entries.count == 1)
        #expect(entries[0].query == "swift concurrency")
    }

    @Test("Adding the same query (case-insensitive) does not create a duplicate")
    func addNoDuplicate() async {
        let store = makeStore()
        await store.add("Swift")
        await store.add("swift")
        let entries = await store.all
        #expect(entries.count == 1)
    }

    @Test("Re-adding an existing query moves it to the top")
    func reAddMovesToTop() async {
        let store = makeStore()
        await store.add("first query")
        await store.add("second query")
        await store.add("first query")
        let entries = await store.all
        #expect(entries[0].query == "first query")
        #expect(entries.count == 2)
    }

    @Test("Entries are sorted newest-first")
    func newestFirst() async {
        let store = makeStore()
        await store.add("oldest")
        await store.add("newest")
        let entries = await store.all
        #expect(entries[0].query == "newest")
        #expect(entries[1].query == "oldest")
    }

    @Test("Adding beyond cap drops the oldest entry")
    func capsAt50() async {
        let store = makeStore()
        for i in 1...51 {
            await store.add("query \(i)")
        }
        let entries = await store.all
        #expect(entries.count == 50)
        // "query 1" was the oldest and should be gone
        #expect(!entries.contains { $0.query == "query 1" })
        // "query 51" is the newest and should be first
        #expect(entries[0].query == "query 51")
    }

    @Test("Blank/whitespace-only queries are ignored")
    func blankQueryIgnored() async {
        let store = makeStore()
        await store.add("   ")
        await store.add("")
        let entries = await store.all
        #expect(entries.isEmpty)
    }

    // MARK: - Remove

    @Test("Removing a query deletes only that entry")
    func removeDeletesSingleEntry() async {
        let store = makeStore()
        await store.add("to remove")
        await store.add("to keep")
        await store.remove("to remove")
        let entries = await store.all
        #expect(entries.count == 1)
        #expect(entries[0].query == "to keep")
    }

    @Test("Removing a non-existent query is a no-op")
    func removeNonExistentIsNoOp() async {
        let store = makeStore()
        await store.add("present")
        await store.remove("absent")
        #expect(await store.all.count == 1)
    }

    // MARK: - Clear

    @Test("Clear removes all entries")
    func clearRemovesAll() async {
        let store = makeStore()
        await store.add("a")
        await store.add("b")
        await store.clear()
        #expect(await store.all.isEmpty)
    }

    // MARK: - Persistence

    @Test("Entries persist across store re-initialization with the same suite name")
    func persistsAcrossReinit() async {
        let suite = "test-persist-\(UUID().uuidString)"
        let store1 = SearchHistoryStore(suiteName: suite)
        await store1.add("persisted query")

        let store2 = SearchHistoryStore(suiteName: suite)
        let entries = await store2.all
        #expect(entries.count == 1)
        #expect(entries[0].query == "persisted query")
    }

    @Test("Different suite names do not share state")
    func isolatedSuites() async {
        let storeA = SearchHistoryStore(suiteName: "test-A-\(UUID().uuidString)")
        let storeB = SearchHistoryStore(suiteName: "test-B-\(UUID().uuidString)")
        await storeA.add("only in A")
        #expect(await storeB.all.isEmpty)
    }
}
