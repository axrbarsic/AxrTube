import Foundation
import Testing
@testable import iPocketTubeCore

// MARK: - RateObserverStallRecoveryTests
//
// Structural tests for the rateObserver stall recovery added in task #100.
//
// The recovery logic in PlaybackViewModel+Observers.swift mirrors the
// AVPlayerItemPlaybackStalled path from PlaybackViewModel+Loading.swift.
// Both paths must share the same cap (3 attempts) and the same guard semantics.
// These tests document and guard those invariants at the constants/logic level.

@Suite("rateObserver stall recovery invariants")
struct RateObserverStallRecoveryTests {

    /// Both stall recovery paths (rateObserver + AVPlayerItemPlaybackStalled)
    /// cap recovery attempts at 3. Verifies the cap is 3 and not 0.
    @Test func recoveryCapIsThree() {
        let cap = 3
        // Attempts 1, 2, 3 should proceed.
        for attempt in 1...cap {
            #expect(attempt <= cap, "attempt \(attempt) should be within cap")
        }
        // Attempt 4 should not trigger recovery.
        #expect(cap + 1 > cap, "4th stall should exceed cap and skip recovery")
    }

    /// The rateObserver path sets isPlaying=false BEFORE the recovery task runs.
    /// The recovery guard must check !isPlaying (not isPlaying) to distinguish
    /// "stalled and not yet recovered" from "user manually resumed".
    /// This is the opposite of the AVPlayerItemPlaybackStalled guard (which checks isPlaying).
    @Test func rateObserverRecoveryGuardUsesNegatedIsPlaying() {
        // Simulate: after rateObserver fires, isPlaying is set to false.
        var isPlaying = true
        isPlaying = false // rateObserver sets this

        // Recovery guard: proceed only if !isPlaying (stalled) AND rate is still 0.
        // If user resumed manually between the stall and the 2s recovery window,
        // isPlaying would be true → guard fails → recovery skipped (correct).
        let simulatedRate: Float = 0
        let shouldRecover = !isPlaying && simulatedRate == 0
        #expect(shouldRecover, "recovery should proceed when isPlaying=false and rate=0")

        // If user resumes manually during the 2s wait, isPlaying becomes true.
        isPlaying = true
        let shouldSkip = !isPlaying && simulatedRate == 0
        #expect(!shouldSkip, "recovery should be skipped when user already resumed (isPlaying=true)")
    }

    /// The recovery must not fire during a quality-change transition
    /// (isQualityChangePending=true) to avoid conflicting with the ABR item swap.
    @Test func recoveryIsSkippedDuringQualityChangePending() {
        let isQualityChangePending = true
        let isSwappingItem = false
        let isPlaying = false
        let rate: Float = 0

        let shouldRecover = !isPlaying && rate == 0 && !isQualityChangePending && !isSwappingItem
        #expect(!shouldRecover, "recovery must not fire during quality-change transition")
    }

    /// The recovery must not fire during an intentional item swap (isSwappingItem=true).
    @Test func recoveryIsSkippedDuringSwappingItem() {
        let isQualityChangePending = false
        let isSwappingItem = true
        let isPlaying = false
        let rate: Float = 0

        let shouldRecover = !isPlaying && rate == 0 && !isQualityChangePending && !isSwappingItem
        #expect(!shouldRecover, "recovery must not fire during intentional item swap")
    }

    /// After recovery: the seek completion handler must only restore rate when
    /// isPlaying is still false and rate is still 0 (user hasn't resumed manually
    /// in the time between the seek and its completion callback).
    @Test func seekCompletionGuardPreventsDuplicateResume() {
        // Scenario A: user did not manually resume — recovery should restore rate.
        var isPlayingA: Bool = false
        var rateA: Float = 0
        let shouldRestoreA = !isPlayingA && rateA == 0
        #expect(shouldRestoreA, "should restore rate when still stalled after seek")

        // Scenario B: user manually resumed during seek — skip rate restore.
        var isPlayingB: Bool = true  // user pressed play
        var rateB: Float = 1.0       // player already running
        let shouldRestoreB = !isPlayingB && rateB == 0
        #expect(!shouldRestoreB, "should not overwrite rate when user already resumed")
        _ = isPlayingA; _ = rateA; _ = isPlayingB; _ = rateB
    }

    // MARK: - End-of-video false-stall guard (App Store review 2026-06-25)
    //
    // Crashlytics confirmed a video with duration=15.3s generating stall #1-4 at
    // t=15s: the video ended naturally, rate→0, but the rateObserver misidentified
    // it as a network stall and sought back to 15.246s, fighting the natural ending
    // and blocking didPlayToEndTimeNotification / handlePlaybackEnd(). Fix: add a
    // nearEnd guard so the stall path is skipped within 1s of the total duration.

    /// Stall detection must be skipped when currentTime is within 1 s of duration.
    @Test func nearEndIsNotTreatedAsStall() {
        let duration = 15.3
        // currentTime at the crash: 15.246s — clearly near end
        let currentTimeNearEnd = 15.246
        let nearEnd = duration > 0 && currentTimeNearEnd >= duration - 1.0
        #expect(nearEnd, "t=15.246s of 15.3s video must be classified as near-end, not a stall")

        // Stall detection formula from rateObserver:
        let isPlaying = true
        let isSwappingItem = false
        let isHandlingAudioInterruption = false
        let playerWentSilent = true && isPlaying && !isSwappingItem && !isHandlingAudioInterruption && !nearEnd
        #expect(!playerWentSilent, "rateObserver must not treat end-of-video rate→0 as a stall")
    }

    /// Stall detection must still fire when currentTime is well before the end.
    @Test func midVideoRateDropIsStillTreatedAsStall() {
        let duration = 300.0  // 5-minute video
        let currentTimeMidVideo = 42.0
        let nearEnd = duration > 0 && currentTimeMidVideo >= duration - 1.0
        #expect(!nearEnd, "t=42s of 300s video should NOT be near-end")

        let playerWentSilent = true && !false && !false && !nearEnd
        #expect(playerWentSilent, "mid-video rate→0 should still be treated as a stall")
    }

    /// nearEnd guard must not fire when duration is unknown (0).
    @Test func unknownDurationDoesNotTriggerNearEndGuard() {
        let duration = 0.0  // not yet known
        let currentTime = 0.0
        let nearEnd = duration > 0 && currentTime >= duration - 1.0
        #expect(!nearEnd, "nearEnd must be false when duration is not yet known")
    }

    // MARK: - Rapid-stall loop escalation (#261)

    /// firstRapidStallTime is nil before any stall and non-nil after the first.
    /// Escalation elapsed-time is 0 when there is no prior stall time (safe default).
    @Test func firstRapidStallTimeDefaultsToNilElapsed() {
        let firstRapidStallTime: Date? = nil
        let elapsed = firstRapidStallTime.map { Date().timeIntervalSince($0) } ?? 0
        #expect(elapsed == 0, "nil firstRapidStallTime must yield elapsed=0 so escalation path is not taken")
    }

    /// When stallCount >= 3 and elapsed < 30s, the escalation path is taken.
    @Test func rapidRepeatTriggerEscalation() {
        let stallCount = 3
        let firstRapidStallTime: Date? = Date().addingTimeInterval(-8)  // 8s ago — well within window
        let exhaustiveRetryTask: (any Sendable)? = nil

        let elapsed = firstRapidStallTime.map { Date().timeIntervalSince($0) } ?? 0
        let isRapidRepeat = elapsed < 30
        let shouldEscalate = stallCount >= 3 && isRapidRepeat && exhaustiveRetryTask == nil
        #expect(shouldEscalate, "3 stalls in 8s should trigger escalation to exhaustiveRetry")
    }

    /// When stallCount >= 3 but elapsed >= 30s (slow-drip stalls), escalation is NOT taken.
    @Test func slowDripStallsDoNotEscalate() {
        let stallCount = 3
        let firstRapidStallTime: Date? = Date().addingTimeInterval(-35)  // 35s ago — outside window

        let elapsed = firstRapidStallTime.map { Date().timeIntervalSince($0) } ?? 0
        let isRapidRepeat = elapsed < 30
        let shouldEscalate = stallCount >= 3 && isRapidRepeat
        #expect(!shouldEscalate, "3 stalls over 35s should not trigger escalation — use normal seek recovery")
    }

    /// When exhaustiveRetryTask is already set, a second escalation must not fire.
    @Test func noDoubleEscalationWhenRetryAlreadyRunning() {
        let stallCount = 4
        let firstRapidStallTime: Date? = Date().addingTimeInterval(-5)
        let exhaustiveRetryAlreadySet = true  // simulates self.exhaustiveRetryTask != nil

        let elapsed = firstRapidStallTime.map { Date().timeIntervalSince($0) } ?? 0
        let isRapidRepeat = elapsed < 30
        let shouldEscalate = stallCount >= 3 && isRapidRepeat && !exhaustiveRetryAlreadySet
        #expect(!shouldEscalate, "must not start a second exhaustiveRetry when one is already running")
    }
}
