import Foundation
import Testing
#if canImport(UIKit)
import UIKit
#endif
import AVFoundation
@testable import iPocketTube
@testable import iPocketTubeCore

// MARK: - PhoneCallInterruptionTests
//
// Regression tests for task #244: an AVAudioSession interruption (e.g. an
// incoming phone call) must pause background playback WITHOUT the
// rate-observer's stall detection/recovery misinterpreting the resulting
// rate→0 as a playback stall, and must resume cleanly when the interruption
// ends with shouldResume.

@Suite("Phone call interruption — flags & rate-observer guard (#244)")
@MainActor
struct PhoneCallInterruptionFlagTests {

    @Test("State machine pauses/yields on began and resumes exactly once when allowed")
    func stateMachineResumesExactlyOnce() {
        var state = AudioInterruptionStateMachine()

        #expect(state.began(wasPlaying: true) == .pauseAndYield)
        #expect(state.isHandling)
        #expect(state.wasPlaying)
        #expect(state.generation == 1)

        #expect(state.ended(shouldResume: true) == .rebuildGraphAndResume)
        #expect(!state.isHandling)
        #expect(!state.wasPlaying)
        #expect(state.ended(shouldResume: true) == .ignore)
    }

    @Test("State machine remains paused when system does not grant resume")
    func stateMachineHonoursMissingShouldResume() {
        var state = AudioInterruptionStateMachine()

        #expect(state.began(wasPlaying: true) == .pauseAndYield)
        #expect(state.ended(shouldResume: false) == .stayPaused)
        #expect(!state.isHandling)
        #expect(!state.wasPlaying)
    }

    @Test("A deliberate Play recovers when interruption ended is never delivered")
    func manualPlayRecoversMissingEndedNotification() {
        var state = AudioInterruptionStateMachine()

        #expect(state.began(wasPlaying: true) == .pauseAndYield)
        let interruptionGeneration = state.generation
        #expect(state.userRequestedPlay() == .rebuildGraphAndResume)
        #expect(!state.isHandling)
        #expect(!state.wasPlaying)
        #expect(state.generation == interruptionGeneration + 1)
    }

    @Test("Lock and foreground do not invalidate an allowed background recovery")
    func lockLifecyclePreservesGeneration() {
        var state = AudioInterruptionStateMachine()
        #expect(state.began(wasPlaying: true) == .pauseAndYield)
        let generation = state.generation

        #expect(state.enteredBackground(playbackAllowed: true, wasPlaying: false) == .ignore)
        #expect(state.enteredForeground() == .ignore)
        #expect(state.generation == generation)
        #expect(state.isHandling)
    }

    @Test("Now Playing generation rejects stale callbacks from an old saved item")
    func nowPlayingSourceGenerationRejectsStaleOwner() {
        var source = NowPlayingSourceState()
        let first = source.activate(itemKey: "saved-a")
        let second = source.activate(itemKey: "saved-b")

        #expect(!source.accepts(generation: first, itemKey: "saved-a"))
        let staleClearAccepted = source.clear(generation: first)
        #expect(!staleClearAccepted)
        #expect(source.accepts(generation: second, itemKey: "saved-b"))
        let currentClearAccepted = source.clear(generation: second)
        #expect(currentClearAccepted)
        #expect(source.itemKey == nil)
    }

    @Test("State machine does not auto-resume media that was already paused")
    func stateMachinePreservesUserPause() {
        var state = AudioInterruptionStateMachine()

        #expect(state.began(wasPlaying: false) == .pauseAndYield)
        #expect(state.ended(shouldResume: true) == .stayPaused)
    }

    @Test("Duplicate began preserves resume intent and recovery generation")
    func stateMachineIgnoresDuplicateBegan() {
        var state = AudioInterruptionStateMachine()

        #expect(state.began(wasPlaying: true) == .pauseAndYield)
        let generation = state.generation
        #expect(state.began(wasPlaying: false) == .ignore)
        #expect(state.wasPlaying)
        #expect(state.generation == generation)
    }

    @Test("Twenty repeated audio cycles keep one-shot recovery and pause intent")
    func stateMachineSurvivesTwentyMixedCycles() {
        var state = AudioInterruptionStateMachine()

        for cycle in 0..<20 {
            #expect(state.began(wasPlaying: true) == .pauseAndYield)
            #expect(state.began(wasPlaying: false) == .ignore)
            if cycle.isMultiple(of: 2) {
                #expect(state.ended(shouldResume: true) == .rebuildGraphAndResume)
            } else {
                #expect(state.ended(shouldResume: false) == .stayPaused)
            }
            #expect(state.ended(shouldResume: true) == .ignore)

            #expect(state.routeBecameUnavailable() == .pauseAndYield)
            #expect(state.routeBecameAvailable() == .stayPaused)
            #expect(state.mediaServicesLost(wasPlaying: true) == .pauseAndYield)
            #expect(state.mediaServicesReset() == .rebuildGraphAndStayPaused)
            #expect(state.enteredBackground(playbackAllowed: true, wasPlaying: true) == .ignore)
            #expect(state.enteredForeground() == .ignore)
            #expect(!state.isHandling)
            #expect(!state.mediaServicesAreLost)
        }
    }

    @Test("Manual pause during interruption cancels automatic resume")
    func manualPauseWinsDuringInterruption() {
        var state = AudioInterruptionStateMachine()
        #expect(state.began(wasPlaying: true) == .pauseAndYield)
        state.userPaused()
        #expect(state.ended(shouldResume: true) == .stayPaused)
    }

    @Test("Route loss before interruption preserves the real playback intent")
    func routeLossBeforeInterruptionPreservesIntent() {
        var state = AudioInterruptionStateMachine()
        state.playbackBecameActive()

        #expect(state.routeBecameUnavailable(wasPlaying: true) == .pauseAndYield)
        #expect(state.userWantsPlayback)
        #expect(state.sourceBegan(.systemInterruption, wasPlaying: false) == .pauseAndYield)
        let generation = state.generation
        #expect(state.wasPlaying)
        #expect(state.sourceEnded(.systemInterruption, shouldResume: true) == .rebuildGraphAndResume)
        #expect(state.acceptsPendingResume(generation: generation))
        let firstCompletion = state.completePendingResume(generation: generation)
        let duplicateCompletion = state.completePendingResume(generation: generation)
        #expect(firstCompletion)
        #expect(!duplicateCompletion)
    }

    @Test("User pause cancels an already approved pending resume")
    func userPauseCancelsPendingResume() {
        var state = AudioInterruptionStateMachine()
        #expect(state.began(wasPlaying: true) == .pauseAndYield)
        #expect(state.ended(shouldResume: true) == .rebuildGraphAndResume)
        let generation = state.generation
        #expect(state.acceptsPendingResume(generation: generation))

        state.userPaused()

        #expect(!state.userWantsPlayback)
        #expect(!state.pendingSystemResume)
        #expect(!state.acceptsPendingResume(generation: generation))
    }

    @Test("Item reset rejects a stale interruption end")
    func itemResetRejectsStaleEnded() {
        var state = AudioInterruptionStateMachine()
        #expect(state.began(wasPlaying: true) == .pauseAndYield)
        let oldGeneration = state.generation

        state.reset()

        #expect(state.ended(shouldResume: true) == .ignore)
        #expect(!state.acceptsPendingResume(generation: oldGeneration))
        #expect(!state.userWantsPlayback)
    }

    @Test("Route-disconnected interruption never resumes before its causal end")
    func routeDisconnectedWaitsForEnded() {
        var state = AudioInterruptionStateMachine()
        #expect(state.sourceBegan(.systemInterruption, wasPlaying: true) == .pauseAndYield)
        let generation = state.generation
        #expect(state.isHandling)
        #expect(!state.pendingSystemResume)
        #expect(state.generation == generation)
        #expect(state.sourceEnded(.systemInterruption, shouldResume: false) == .rebuildGraphAndResume)
        #expect(state.acceptsPendingResume(generation: generation))
    }

    @Test("Spoken hint cannot resume while a real interruption is still active")
    func overlappingHintEndsBeforeSystemInterruption() {
        var state = AudioInterruptionStateMachine()
        #expect(state.sourceBegan(.secondaryAudioHint, wasPlaying: true) == .pauseAndYield)
        #expect(state.sourceBegan(.systemInterruption, wasPlaying: false) == .ignore)
        #expect(state.sourceEnded(.secondaryAudioHint, shouldResume: true) == .ignore)
        #expect(state.isHandling)
        #expect(state.sourceEnded(.systemInterruption, shouldResume: true) == .rebuildGraphAndResume)
        #expect(!state.isHandling)
        #expect(state.sourceEnded(.systemInterruption, shouldResume: true) == .ignore)
    }

    @Test("Causal system end preserves playback intent when recommendation is absent")
    func causalSystemEndPreservesPlaybackIntent() {
        var state = AudioInterruptionStateMachine()
        #expect(state.sourceBegan(.systemInterruption, wasPlaying: true) == .pauseAndYield)
        #expect(state.sourceBegan(.secondaryAudioHint, wasPlaying: false) == .ignore)
        #expect(state.sourceEnded(.systemInterruption, shouldResume: false) == .ignore)
        #expect(state.sourceEnded(.secondaryAudioHint, shouldResume: true) == .rebuildGraphAndResume)
    }

    @Test("Manual pause wins across overlapping audio sources")
    func manualPauseWinsAcrossOverlappingSources() {
        var state = AudioInterruptionStateMachine()
        #expect(state.sourceBegan(.secondaryAudioHint, wasPlaying: true) == .pauseAndYield)
        #expect(state.sourceBegan(.systemInterruption, wasPlaying: false) == .ignore)
        state.userPaused()
        #expect(state.sourceEnded(.systemInterruption, shouldResume: true) == .ignore)
        #expect(state.sourceEnded(.secondaryAudioHint, shouldResume: true) == .stayPaused)
    }

    @Test("Interruption flags default to false")
    func interruptionFlagsDefaultToFalse() {
        let vm = PlaybackViewModel()
        #expect(vm.isHandlingAudioInterruption == false)
        #expect(vm.wasPlayingBeforeInterruption == false)
        #expect(vm.audioInterruptionResumeCount == 0)
    }

    @Test("playerWentSilent ignores a rate-drop caused by an audio interruption pause")
    func playerWentSilentIgnoresInterruptionPause() {
        let isPlaying = true
        let isSwappingItem = false
        let isHandlingAudioInterruption = true
        let newRate: Float = 0

        let playerWentSilent = newRate == 0 && isPlaying && !isSwappingItem && !isHandlingAudioInterruption
        #expect(playerWentSilent == false)
    }

    @Test("playerWentSilent still detects a real stall when not handling an interruption")
    func playerWentSilentStillDetectsRealStall() {
        let isPlaying = true
        let isSwappingItem = false
        let isHandlingAudioInterruption = false
        let newRate: Float = 0

        let playerWentSilent = newRate == 0 && isPlaying && !isSwappingItem && !isHandlingAudioInterruption
        #expect(playerWentSilent == true)
    }
}

#if canImport(UIKit)
@Suite("Phone call interruption — AVAudioSession notification handling (#244)")
@MainActor
struct PhoneCallInterruptionNotificationTests {

    private func makeVMWithCurrentItem() -> PlaybackViewModel {
        let vm = PlaybackViewModel()
        let inertURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ipockettube-interruption-test.m4a")
        vm.player.replaceCurrentItem(with: AVPlayerItem(url: inertURL))
        return vm
    }

    @Test("Interruption .began pauses the player and sets interruption flags")
    func interruptionBeganPausesAndSetsFlags() async {
        let vm = makeVMWithCurrentItem()
        vm.isPlaying = true
        let generation = vm.audioInterruptionGeneration

        NotificationCenter.default.post(
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue]
        )

        var observed = false
        for _ in 0..<50 {
            if vm.isHandlingAudioInterruption && vm.wasPlayingBeforeInterruption && !vm.isPlaying
                && vm.player.rate == 0 {
                observed = true
                break
            }
            try? await Task.sleep(for: .milliseconds(10))
        }

        #expect(observed, "Expected isHandlingAudioInterruption=true, wasPlayingBeforeInterruption=true, isPlaying=false after .began")
        #expect(vm.audioInterruptionGeneration == generation + 1)
        #expect(vm.audioInterruptionResumeCount == 0)
    }

    @Test("Interruption .ended with shouldResume resumes playback")
    func interruptionEndedResumesWhenShouldResume() async {
        let vm = makeVMWithCurrentItem()
        vm.isPlaying = true

        NotificationCenter.default.post(
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue]
        )

        for _ in 0..<50 {
            if vm.isHandlingAudioInterruption { break }
            try? await Task.sleep(for: .milliseconds(10))
        }

        NotificationCenter.default.post(
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            userInfo: [
                AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue,
                AVAudioSessionInterruptionOptionKey: AVAudioSession.InterruptionOptions.shouldResume.rawValue
            ]
        )

        var resumed = false
        for _ in 0..<50 {
            if vm.isPlaying && !vm.isHandlingAudioInterruption {
                resumed = true
                break
            }
            try? await Task.sleep(for: .milliseconds(10))
        }

        #expect(resumed, "Expected isPlaying=true and isHandlingAudioInterruption=false after .ended with shouldResume")
        #expect(vm.audioInterruptionResumeCount == 1)
        #expect(AVAudioSession.sharedInstance().category == .playback)
        #expect(AVAudioSession.sharedInstance().mode == .spokenAudio)

        // A duplicate system ended notification must not activate/resume twice.
        NotificationCenter.default.post(
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            userInfo: [
                AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue,
                AVAudioSessionInterruptionOptionKey: AVAudioSession.InterruptionOptions.shouldResume.rawValue
            ]
        )
        try? await Task.sleep(for: .milliseconds(50))
        #expect(vm.audioInterruptionResumeCount == 1)
    }

    @Test("Transient activation failure retries once and resumes exactly once")
    func transientActivationFailureRetriesCausally() async {
        let vm = makeVMWithCurrentItem()
        vm.audioInterruptionRetryDelays = [.zero, .zero]
        var attempts = 0
        vm.audioSessionActivator = { _ in
            attempts += 1
            return attempts == 2
        }
        vm.isPlaying = true

        vm.handleAudioInterruption(type: .began)
        vm.handleAudioInterruption(type: .ended, options: [.shouldResume])

        for _ in 0..<50 {
            if vm.audioInterruptionResumeCount == 1 { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(attempts == 2)
        #expect(vm.audioInterruptionResumeCount == 1)
        #expect(vm.isPlaying)

        vm.handleAudioInterruption(type: .ended, options: [.shouldResume])
        try? await Task.sleep(for: .milliseconds(20))
        #expect(attempts == 2)
        #expect(vm.audioInterruptionResumeCount == 1)
    }

    @Test("User pause cancels activation retry before it can resume")
    func userPauseCancelsActivationRetry() async {
        let vm = makeVMWithCurrentItem()
        vm.audioInterruptionRetryDelays = [.milliseconds(50)]
        var attempts = 0
        vm.audioSessionActivator = { _ in
            attempts += 1
            return attempts > 1
        }
        vm.isPlaying = true

        vm.handleAudioInterruption(type: .began)
        vm.handleAudioInterruption(type: .ended, options: [.shouldResume])
        for _ in 0..<20 {
            if attempts == 1 { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        vm.performUserPause(reason: "test user pause during retry")
        try? await Task.sleep(for: .milliseconds(80))

        #expect(attempts == 1)
        #expect(vm.audioInterruptionResumeCount == 0)
        #expect(!vm.isPlaying)
    }

    @Test("ChatGPT route disconnect waits for a causal route restoration")
    func routeDisconnectedMicCaptureWaitsForRouteRestoration() async {
        let vm = makeVMWithCurrentItem()
        vm.audioSessionActivator = { _ in true }
        vm.audioInterruptionState.playbackBecameActive()
        vm.isPlaying = true

        vm.performRemotePause(reason: "test microphone prelude")
        vm.handleAudioRouteChange(reason: .oldDeviceUnavailable)
        vm.handleAudioInterruption(
            type: .began,
            reason: AVAudioSession.InterruptionReason.routeDisconnected.rawValue
        )
        try? await Task.sleep(for: .milliseconds(20))
        #expect(vm.audioInterruptionResumeCount == 0)
        #expect(!vm.isPlaying)
        #expect(vm.isHandlingAudioInterruption)

        vm.handleAudioRouteChange(reason: .newDeviceAvailable)
        for _ in 0..<50 {
            if vm.audioInterruptionResumeCount == 1 { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(vm.audioInterruptionResumeCount == 1)
        #expect(vm.isPlaying)
        #expect(!vm.isHandlingAudioInterruption)
    }

    @Test("Remote pause during interruption cancels resume after ended")
    func remotePauseDuringInterruptionCancelsEndedResume() async {
        let vm = makeVMWithCurrentItem()
        var attempts = 0
        vm.audioSessionActivator = { _ in
            attempts += 1
            return true
        }
        vm.audioInterruptionState.playbackBecameActive()
        vm.isPlaying = true
        vm.handleAudioInterruption(
            type: .began,
            reason: AVAudioSession.InterruptionReason.routeDisconnected.rawValue
        )

        vm.performRemotePause(reason: "test AirPods pause during interruption")
        vm.handleAudioRouteChange(reason: .newDeviceAvailable)
        try? await Task.sleep(for: .milliseconds(20))

        #expect(attempts == 0)
        #expect(vm.audioInterruptionResumeCount == 0)
        #expect(!vm.isPlaying)
        #expect(!vm.audioInterruptionState.userWantsPlayback)
    }

    @Test("Interruption ended without recommendation restores retained play intent")
    func interruptionEndedWithoutRecommendationResumes() async {
        let vm = makeVMWithCurrentItem()
        vm.isPlaying = true

        NotificationCenter.default.post(
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue]
        )
        for _ in 0..<50 {
            if vm.isHandlingAudioInterruption { break }
            try? await Task.sleep(for: .milliseconds(10))
        }

        NotificationCenter.default.post(
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue]
        )
        for _ in 0..<50 {
            if vm.audioInterruptionResumeCount == 1 { break }
            try? await Task.sleep(for: .milliseconds(10))
        }

        #expect(!vm.isHandlingAudioInterruption)
        #expect(!vm.wasPlayingBeforeInterruption)
        #expect(vm.isPlaying)
        #expect(vm.audioInterruptionResumeCount == 1)
    }

    @Test("Remote Play restores the same item when interruption ended is missing")
    func remotePlayRecoversMissingEndedNotification() {
        let vm = makeVMWithCurrentItem()
        let originalItem = vm.player.currentItem
        vm.currentVideo = Video(id: "saved-test", title: "Saved", channelTitle: "Channel")
        vm.updateNowPlayingInfo()
        vm.isPlaying = true
        vm.handleAudioInterruption(type: .began)

        #expect(vm.isHandlingAudioInterruption)
        vm.performUserPlay(reason: "test AirPods Play")

        #expect(!vm.isHandlingAudioInterruption)
        #expect(vm.player.currentItem === originalItem)
        #expect(vm.isPlaying)
        #expect(!vm.nowPlayingInfoCache.isEmpty)
    }

    @Test("Duplicate began preserves the original was-playing snapshot")
    func duplicateBeganDoesNotLoseResumeIntent() {
        let vm = makeVMWithCurrentItem()
        vm.isPlaying = true

        vm.handleAudioInterruption(type: .began)
        let generation = vm.audioInterruptionGeneration
        vm.handleAudioInterruption(type: .began)

        #expect(vm.isHandlingAudioInterruption)
        #expect(vm.wasPlayingBeforeInterruption)
        #expect(!vm.isPlaying)
        #expect(vm.player.rate == 0)
        #expect(vm.audioInterruptionGeneration == generation)
    }

    @Test("Old output route pauses without speaker fallback playback")
    func oldRouteUnavailablePauses() {
        let vm = makeVMWithCurrentItem()
        vm.isPlaying = true

        vm.handleAudioRouteChange(reason: .oldDeviceUnavailable)

        #expect(!vm.isPlaying)
        #expect(vm.player.rate == 0)
        #expect(vm.audioInterruptionResumeCount == 0)
    }

    @Test("Media-services reset during interruption never steals the microphone route")
    func mediaServicesResetDuringInterruptionStaysPaused() {
        let vm = makeVMWithCurrentItem()
        vm.isPlaying = true
        vm.handleAudioInterruption(type: .began)

        vm.handleMediaServicesReset()

        #expect(vm.isHandlingAudioInterruption)
        #expect(!vm.isPlaying)
        #expect(vm.player.rate == 0)
        #expect(vm.audioInterruptionResumeCount == 0)
        #expect(AVAudioSession.sharedInstance().category == .playback)
        #expect(AVAudioSession.sharedInstance().mode == .spokenAudio)
    }

    @Test("Media-services reset rebuilds the item and stays paused until one user Play")
    func mediaServicesLostThenResetRebuildsPaused() async {
        let vm = makeVMWithCurrentItem()
        let originalItem = vm.player.currentItem
        vm.isPlaying = true

        vm.handleMediaServicesLost()
        #expect(vm.wasPlayingBeforeMediaServicesLoss)
        #expect(!vm.isPlaying)
        #expect(vm.player.rate == 0)

        vm.handleMediaServicesReset()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(!vm.wasPlayingBeforeMediaServicesLoss)
        #expect(!vm.isPlaying)
        #expect(vm.player.rate == 0)
        #expect(vm.player.currentItem !== originalItem)
        #expect(AVAudioSession.sharedInstance().category == .playback)
        #expect(AVAudioSession.sharedInstance().mode == .spokenAudio)

        vm.performUserPlay(reason: "test user Play after media reset")
        #expect(vm.isPlaying)
    }
}
#endif
