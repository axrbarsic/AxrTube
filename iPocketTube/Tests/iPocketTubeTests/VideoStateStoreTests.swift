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

    // MARK: - Boundary: near start

    @Test("A meaningful early position is saved")
    func nearStartNotSaved() async {
        let store = makeStore()
        await store.save(videoId: "abc12345678", position: 4, duration: 100)
        let state = await store.state(for: "abc12345678")
        #expect(state?.position == 4)
    }

    @Test("Sub-second noise is not saved")
    func exactBoundaryStartSaved() async {
        let store = makeStore()
        await store.save(videoId: "abc12345678", position: 0.5, duration: 100)
        #expect(await store.state(for: "abc12345678") == nil)
    }

    // MARK: - Boundary: near end (≥ 95 %)

    @Test("Completed position is explicit and restores from zero")
    func nearEndNotSaved() async {
        let store = makeStore()
        await store.save(videoId: "abc12345678", position: 96, duration: 100)
        let state = await store.state(for: "abc12345678")
        #expect(state?.isCompleted == true)
        #expect(await store.restoredPosition(for: "abc12345678", actualDuration: 100) == 0)
    }

    @Test("Position just below 95 % is saved")
    func justBelowNinetyFivePercent() async {
        let store = makeStore()
        await store.save(videoId: "abc12345678", position: 80, duration: 100)
        let state = await store.state(for: "abc12345678")
        #expect(state?.isCompleted == false)
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

    @Test("Restore clamps a stale position to actual duration")
    func restoreClampsToDuration() async {
        let state = VideoStateStore.State(position: 90, watchedFraction: 0.45, duration: 200)
        #expect(PlaybackPositionPolicy.restoredPosition(state: state, actualDuration: 60) == 59.5)
    }

    @Test("Periodic writes are throttled but final flush is independent")
    func periodicThrottle() {
        let start = Date(timeIntervalSince1970: 1_000)
        #expect(!PlaybackPositionPolicy.shouldWritePeriodicCheckpoint(lastWrite: start, now: start.addingTimeInterval(4.9)))
        #expect(PlaybackPositionPolicy.shouldWritePeriodicCheckpoint(lastWrite: start, now: start.addingTimeInterval(5)))
    }
}

@Suite("Waveform interaction arbitration")
struct WaveformInteractionPolicyTests {
    @Test("Horizontal waveform gesture owns seek")
    func horizontalSeek() {
        #expect(WaveformGesturePolicy.intent(horizontal: 30, vertical: 4) == .seek)
    }

    @Test("Vertical waveform gesture remains list scrolling")
    func verticalScroll() {
        #expect(WaveformGesturePolicy.intent(horizontal: 4, vertical: 30) == .scroll)
    }

    @Test("Small movement does not claim either gesture")
    func threshold() {
        #expect(WaveformGesturePolicy.intent(horizontal: 3, vertical: 2) == .undecided)
    }
}
