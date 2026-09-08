import AVFoundation
import Testing
@testable import iPocketTube

@Suite("Background playback policy")
struct BackgroundPlaybackPolicyTests {
    @Test @MainActor func sharedPlayerExplicitlyContinuesInBackground() {
        let vm = PlaybackViewModel()
        #expect(vm.player.audiovisualBackgroundPlaybackPolicy == .continuesIfPossible)
        vm.handleSceneInactive()
        vm.handleBackground()
        vm.handleForeground()
        // Lifecycle changes must not turn a stopped player into playback.
        #expect(vm.player.rate == 0)
        #expect(vm.player.currentItem == nil)
    }
}
