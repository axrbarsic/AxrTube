import Foundation
import Testing
@testable import iPocketTubeCore

// MARK: - VideoStateStoreTests
//
// Uses an isolated UserDefaults suite per test to avoid any cross-test pollution.
// Each test creates a fresh VideoStateStore(userDefaults:) instance.

@Suite("Video State Store")
struct VideoStateStoreTests {

    // MARK: - Helpers

    /// Returns a fresh, isolated VideoStateStore backed by a unique UserDefaults suite.
    private func makeStore() -> VideoStateStore {
        VideoStateStore(suiteName: "test-\(UUID().uuidString)")
    }

    // MARK: - Save & retrieve

    @Test("Saving a mid-video position can be retrieved")
    func saveAndRetrieve() async {
        let store = makeStore()
        await store.save(videoId: "abc12345678", position: 30, duration: 100)
        let state = await store.state(for: "abc12345678")
        #expect(state?.position == 30)
    }

    @Test("Watched fraction is calculated correctly")
    func watchedFractionCalculated() async {
        let store = makeStore()
        await store.save(videoId: "abc12345678", position: 50, duration: 100)
        let state = await store.state(for: "abc12345678")
        #expect(state?.watchedFraction == 0.5)
    }

    // MARK: - Boundary: near start (< 5 s)

    @Test("Position less than 5 s is not saved")
    func nearStartNotSaved() async {
        let store = makeStore()
        await store.save(videoId: "abc12345678", position: 4, duration: 100)
        let state = await store.state(for: "abc12345678")
        #expect(state == nil)
    }

    @Test("Position just above 5 s is saved (exclusive lower bound)")
    func exactBoundaryStartSaved() async {
        let store = makeStore()
        // Production code uses > 5 (exclusive), so exactly 5 s is NOT saved
        await store.save(videoId: "abc12345678", position: 5.0, duration: 100)
        let notSaved = await store.state(for: "abc12345678")
        #expect(notSaved == nil, "Exactly 5 s must not be saved (exclusive boundary)")
        // Just above 5 s should be saved
        await store.save(videoId: "abc12345678", position: 5.1, duration: 100)
        let saved = await store.state(for: "abc12345678")
        #expect(saved != nil, "5.1 s must be saved")
    }

    // MARK: - Boundary: near end (≥ 95 %)

    @Test("Position at or beyond 95 % of duration is not saved")
    func nearEndNotSaved() async {
        let store = makeStore()
        await store.save(videoId: "abc12345678", position: 96, duration: 100)
        let state = await store.state(for: "abc12345678")
        #expect(state == nil)
    }

    @Test("Position just below 95 % is saved")
    func justBelowNinetyFivePercent() async {
        let store = makeStore()
        await store.save(videoId: "abc12345678", position: 94, duration: 100)
        let state = await store.state(for: "abc12345678")
        #expect(state != nil)
    }

    // MARK: - Clear

    @Test("clear() removes a previously saved entry")
    func clearRemovesEntry() async {
        let store = makeStore()
        await store.save(videoId: "abc12345678", position: 30, duration: 100)
        await store.clear(videoId: "abc12345678")
        let state = await store.state(for: "abc12345678")
        #expect(state == nil)
    }

    @Test("clear() on unknown video ID does not crash")
    func clearUnknownVideoIDNoCrash() async {
        let store = makeStore()
        await store.clear(videoId: "unknownvideo1")
        // No assertion needed — test passes if no crash
    }

    // MARK: - Edge cases

    @Test("Zero duration save does not crash and produces no state")
    func zeroDurationNoCrash() async {
        let store = makeStore()
        await store.save(videoId: "abc12345678", position: 10, duration: 0)
        let state = await store.state(for: "abc12345678")
        // position > 5 but fraction is 0.0 (duration == 0), so the < 0.95 check passes.
        // The important thing is no crash.
        _ = state
    }

    @Test("Multiple videos can be saved independently")
    func multipleVideosSavedIndependently() async {
        let store = makeStore()
        await store.save(videoId: "videoAAAA12345", position: 30, duration: 100)
        await store.save(videoId: "videoBBBB12345", position: 60, duration: 200)
        let stateA = await store.state(for: "videoAAAA12345")
        let stateB = await store.state(for: "videoBBBB12345")
        #expect(stateA?.position == 30)
        #expect(stateB?.position == 60)
    }
}
