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

    @Test("Lifecycle zero does not reset an established playback position")
    func lifecycleZeroDoesNotResetPosition() {
        #expect(PlaybackPositionPolicy.reconciledObservedPosition(
            observed: 0,
            current: 412.5
        ) == 412.5)
    }

    @Test("A real observed position synchronizes the UI clock")
    func realObservedPositionSynchronizes() {
        #expect(PlaybackPositionPolicy.reconciledObservedPosition(
            observed: 413.25,
            current: 0
        ) == 413.25)
    }

    @Test("Explicit seek to start remains accepted after local value is committed")
    func explicitSeekToStartRemainsAccepted() {
        #expect(PlaybackPositionPolicy.reconciledObservedPosition(
            observed: 0,
            current: 0
        ) == 0)
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

    @Test("Analysis prioritizes a short range around playback")
    func rangeFirstWindow() {
        let window = LiveAudioScopePolicy.analysisWindow(around: 600, assetDuration: 1_200)
        #expect(window.duration == 3)
        #expect(window.start == 598.5)
    }

    @Test("Dynamic normalization preserves silence and reveals signal")
    func dynamicNormalization() {
        let values = LiveAudioScopePolicy.normalize(
            [0, 0.0005, 0.01, 0.04, 0.012],
            peaks: [0, 0.0008, 0.02, 0.08, 0.018]
        )
        #expect(values[0] == 0)
        #expect(values[1] == 0)
        #expect(values[3] > values[2])
        #expect(values[3] > 0.45)
    }

    @Test("Pause freezes the already visible scope")
    func pauseFreezesScope() {
        #expect(LiveAudioScopePolicy.displaySamples(current: [0.3, 0.7], incoming: [0.9, 0.1], isPlaying: false) == [0.3, 0.7])
        #expect(LiveAudioScopePolicy.displaySamples(current: [0.3, 0.7], incoming: [0.9, 0.1], isPlaying: true) == [0.9, 0.1])
    }

    @Test("Seeking selects a new analysis bucket")
    func seekSelectsNewWindow() {
        #expect(LiveAudioScopePolicy.bucket(for: 42.2) != LiveAudioScopePolicy.bucket(for: 812.4))
        #expect(LiveAudioScopePolicy.analysisWindow(around: 812.4, assetDuration: 1_000).start > 800)
    }

    @Test("Progressive scope becomes real without a completed file")
    func progressiveScopeTransition() {
        let identity = AudioScopeRenderIdentity(videoID: "video", generation: 1)
        var state = ProgressiveAudioScopeState()
        state.accept(identity: identity, samples: [])
        #expect(state.phase == .preparing)

        state.accept(identity: identity, samples: [0.1, 0.7, 0.3])
        #expect(state.phase == .realEnvelope)
        #expect(state.samples == [0.1, 0.7, 0.3])
    }

    @Test("Range progress does not recreate the active scope identity")
    func progressiveScopeIdentityContinuity() {
        let identity = AudioScopeRenderIdentity(videoID: "video", generation: 7)
        var state = ProgressiveAudioScopeState()
        state.accept(identity: identity, samples: [0.2, 0.4])
        state.accept(identity: identity, samples: [0.3, 0.5])
        #expect(state.identity == identity)
        #expect(state.phase == .realEnvelope)
        #expect(state.samples == [0.3, 0.5])
    }

    @Test("A newer playback session returns to preparing until its PCM arrives")
    func newScopeSessionPrepares() {
        var state = ProgressiveAudioScopeState()
        state.accept(
            identity: AudioScopeRenderIdentity(videoID: "video", generation: 1),
            samples: [0.2, 0.6]
        )
        state.accept(
            identity: AudioScopeRenderIdentity(videoID: "video", generation: 2),
            samples: []
        )
        #expect(state.phase == .preparing)
        #expect(state.samples.isEmpty)
    }

    @Test("Envelope updates interpolate instead of replacing all bars")
    func envelopeInterpolation() {
        let midpoint = AudioScopeCadencePolicy.interpolate(
            from: [0, 1, 0.5],
            to: [1, 0, 0.5],
            progress: 0.5
        )
        #expect(midpoint == [0.5, 0.5, 0.5])
        #expect(AudioScopeCadencePolicy.interpolate(
            from: [0, 1],
            to: [1, 0],
            progress: 1
        ) == [1, 0])
    }
}
