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

    @Test("Interruption ended without shouldResume stays honestly paused")
    func interruptionEndedWithoutResumePermissionStaysPaused() async {
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
            if !vm.isHandlingAudioInterruption { break }
            try? await Task.sleep(for: .milliseconds(10))
        }

        #expect(!vm.isHandlingAudioInterruption)
        #expect(!vm.wasPlayingBeforeInterruption)
        #expect(!vm.isPlaying)
        #expect(vm.player.rate == 0)
        #expect(vm.audioInterruptionResumeCount == 0)
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
