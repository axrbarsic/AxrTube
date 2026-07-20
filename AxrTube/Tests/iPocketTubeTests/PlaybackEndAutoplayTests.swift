import Foundation
import Testing
@testable import iPocketTube
@testable import iPocketTubeCore

// MARK: - PlaybackEndAutoplayTests
//
// Regression tests for task #243: when the user's queue (CurrentQueueStore) is
// exhausted at the end of playback, handlePlaybackEnd() must fall through to
// YouTube's recommended videos (relatedVideos) the same way it already does
// when there's no queue at all — instead of unconditionally setting
// videoEnded = true. This matters most for background playback, where the
// user has no UI affordance to manually start the next video.

@Suite("Playback end — queue exhaustion autoplay (#243)")
@MainActor
struct PlaybackEndAutoplayTests {

    @Test("Queue exhausted + autoplay enabled → falls through to first related video")
    func queueExhaustionFallsThroughToRecommendations() async throws {
        await CurrentQueueStore.shared.clear()
        defer { Task { await CurrentQueueStore.shared.clear() } }

        let queuedVideo = Video(id: "queued-1", title: "Queued Video", channelTitle: "Ch")
        await CurrentQueueStore.shared.replaceAll(with: [queuedVideo])

        let vm = PlaybackViewModel()
        vm.settings.loopEnabled = false
        vm.settings.queueShuffleEnabled = false
        vm.settings.shuffleEnabled = false
        vm.settings.autoplayEnabled = true

        // currentVideo is the single queue item at index 0, tagged with playlistId/playlistIndex
        vm.currentVideo = await CurrentQueueStore.shared.videoAt(index: 0)

        let recommended = Video(id: "recommended-1", title: "Recommended Video", channelTitle: "Ch")
        vm.relatedVideos = [recommended]

        vm.handlePlaybackEnd()

        // handlePlaybackEnd() spawns a Task that awaits CurrentQueueStore — poll for the result.
        var loadedRecommended = false
        for _ in 0..<50 {
            if vm.currentVideo?.id == recommended.id {
                loadedRecommended = true
                break
            }
            try? await Task.sleep(for: .milliseconds(10))
        }

        #expect(loadedRecommended, "Expected autoplay to fall through to the first related video after the queue was exhausted")
        #expect(vm.videoEnded == false, "videoEnded must not be set when a recommendation was loaded")
    }

    @Test("Queue exhausted + autoplay disabled + no related videos → videoEnded becomes true")
    func queueExhaustionWithNoFallbackEndsVideo() async throws {
        await CurrentQueueStore.shared.clear()
        defer { Task { await CurrentQueueStore.shared.clear() } }

        let queuedVideo = Video(id: "queued-2", title: "Queued Video", channelTitle: "Ch")
        await CurrentQueueStore.shared.replaceAll(with: [queuedVideo])

        let vm = PlaybackViewModel()
        vm.settings.loopEnabled = false
        vm.settings.queueShuffleEnabled = false
        vm.settings.shuffleEnabled = false
        vm.settings.autoplayEnabled = false

        vm.currentVideo = await CurrentQueueStore.shared.videoAt(index: 0)
        vm.relatedVideos = []

        vm.handlePlaybackEnd()

        var ended = false
        for _ in 0..<50 {
            if vm.videoEnded {
                ended = true
                break
            }
            try? await Task.sleep(for: .milliseconds(10))
        }

        #expect(ended, "videoEnded should become true when the queue is exhausted and there is nothing to autoplay")
    }
}
