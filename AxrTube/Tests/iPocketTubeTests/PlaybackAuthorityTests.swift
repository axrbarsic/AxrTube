import AVFoundation
import Foundation
import Testing
@testable import iPocketTube
@testable import iPocketTubeCore

@Suite("Playback authority") @MainActor
struct PlaybackAuthorityTests {
    @Test func newSelectionDoesNotEraseOverlappingSystemAudioOwners() {
        var state = AudioInterruptionStateMachine()
        state.selectedItem()
        #expect(state.allowsAutomaticPlayback)
        #expect(state.sourceBegan(.systemInterruption, wasPlaying: true) == .pauseAndYield)
        _ = state.sourceBegan(.secondaryAudioHint, wasPlaying: false)
        state.selectedItem()
        #expect(!state.allowsAutomaticPlayback)
        state.playbackBecameActive()
        #expect(state.isHandling)
        #expect(state.sourceEnded(.systemInterruption, shouldResume: true) == .ignore)
        #expect(!state.allowsAutomaticPlayback)
        #expect(state.sourceEnded(.secondaryAudioHint, shouldResume: true) == .rebuildGraphAndResume)
        #expect(state.allowsAutomaticPlayback)
    }

    @Test func lateMediaAndQualityReadinessCannotUndoUserPauseOrInterruption() {
        let vm = PlaybackViewModel()
        let item = AVPlayerItem(asset: AVMutableComposition())
        vm.player.replaceCurrentItem(with: item)
        vm.audioInterruptionState.selectedItem()
        _ = vm.audioInterruptionState.sourceBegan(.systemInterruption, wasPlaying: true)
        #expect(!vm.requestPlaybackStart(expectedItem: item))
        vm.qualityItemDidBecomeReady(item, seekTo: 0)
        #expect(vm.player.rate == 0)
        #expect(!vm.isPlaying)
        vm.audioInterruptionState.userPaused()
        _ = vm.audioInterruptionState.sourceEnded(.systemInterruption, shouldResume: true)
        #expect(!vm.requestPlaybackStart(expectedItem: item))
        #expect(vm.enforcePlaybackAuthority())
        #expect(vm.player.rate == 0)
    }

    @Test func staleItemCannotTakeOwnershipOfNewItem() {
        let vm = PlaybackViewModel()
        let stale = AVPlayerItem(asset: AVMutableComposition())
        let current = AVPlayerItem(asset: AVMutableComposition())
        vm.player.replaceCurrentItem(with: current)
        vm.audioInterruptionState.selectedItem()
        vm.isQualityChangePending = true
        vm.qualityItemDidBecomeReady(stale, seekTo: 42)
        #expect(vm.isQualityChangePending)
        #expect(vm.currentTime == 0)
        #expect(!vm.requestPlaybackStart(expectedItem: stale))
        #expect(vm.player.currentItem === current)
    }

    @Test func mediaServicesLossSurvivesNewItemSelection() {
        var state = AudioInterruptionStateMachine()
        state.selectedItem()
        _ = state.mediaServicesLost(wasPlaying: true)
        state.selectedItem()
        #expect(!state.allowsAutomaticPlayback)
        #expect(state.mediaServicesReset() == .rebuildGraphAndStayPaused)
        #expect(!state.allowsAutomaticPlayback)
    }
}
