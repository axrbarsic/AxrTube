#if !os(tvOS)
import Foundation
import Testing
@testable import iPocketTube
@testable import iPocketTubeCore

// MARK: - TOSPlaybackEndAutoplayTests
//
// Regression tests for #109: TOSPlayerViewModel had zero end-of-video handling
// at all — never ported from PlaybackViewModel+Navigation.handlePlaybackEnd()
// when TOS became the iOS default. Every video just stopped at YouTube's own
// native "replay" end screen regardless of the Autoplay/queue settings.
//
// Mirrors PlaybackEndAutoplayTests.swift's pattern (task #243) for the TOS
// pipeline's handlePlaybackEnd(), which delegates the actual queue-vs-
// suggestions navigation to the already-tested playNext() — these tests only
// need to verify handlePlaybackEnd()'s own gating decision.

@Suite("TOS playback end — autoplay/queue gating (#109)")
@MainActor
struct TOSPlaybackEndAutoplayTests {

    @Test("Queue context advances unconditionally, even with Autoplay disabled")
    func queueContextAdvancesRegardlessOfAutoplaySetting() async throws {
        await CurrentQueueStore.shared.clear()
        defer { Task { await CurrentQueueStore.shared.clear() } }

        let queuedVideo = Video(id: "tos-queued-1", title: "Queued", channelTitle: "Ch")
        let nextVideo = Video(id: "tos-queued-2", title: "Next Queued", channelTitle: "Ch")
        await CurrentQueueStore.shared.replaceAll(with: [queuedVideo, nextVideo])

        let vm = TOSPlayerViewModel(
            videoId: queuedVideo.id,
            playlistId: CurrentQueueStore.playlistID,
            playlistIndex: 0,
            api: InnerTubeAPI()
        )
        var settings = AppSettings()
        settings.autoplayEnabled = false
        settings.loopEnabled = false
        vm.updateSettings(settings)

        var advancedTo: Video?
        vm.onPlayNext = { advancedTo = $0 }

        vm.handlePlaybackEnd()

        // playNext()'s queue path spawns a Task that awaits CurrentQueueStore — poll.
        var fired = false
        for _ in 0..<50 {
            if advancedTo != nil { fired = true; break }
            try? await Task.sleep(for: .milliseconds(10))
        }

        #expect(fired, "Queue continuation must happen even when Autoplay is disabled")
        #expect(advancedTo?.id == nextVideo.id)
    }

    @Test("Non-queue + Autoplay enabled → advances to first related video")
    func autoplayEnabledAdvancesToSuggestion() throws {
        let vm = TOSPlayerViewModel(videoId: "tos-standalone-1", api: InnerTubeAPI())
        var settings = AppSettings()
        settings.autoplayEnabled = true
        settings.loopEnabled = false
        vm.updateSettings(settings)

        let suggestion = Video(id: "tos-suggestion-1", title: "Suggested", channelTitle: "Ch")
        vm.relatedVideos = [suggestion]

        var advancedTo: Video?
        vm.onPlayNext = { advancedTo = $0 }

        vm.handlePlaybackEnd()

        #expect(advancedTo?.id == suggestion.id, "Expected autoplay to advance to the first related video")
    }

    @Test("Non-queue + Autoplay disabled → does not advance")
    func autoplayDisabledDoesNotAdvance() throws {
        let vm = TOSPlayerViewModel(videoId: "tos-standalone-2", api: InnerTubeAPI())
        var settings = AppSettings()
        settings.autoplayEnabled = false
        settings.loopEnabled = false
        vm.updateSettings(settings)

        let suggestion = Video(id: "tos-suggestion-2", title: "Suggested", channelTitle: "Ch")
        vm.relatedVideos = [suggestion]

        var advanced = false
        vm.onPlayNext = { _ in advanced = true }

        vm.handlePlaybackEnd()

        #expect(!advanced, "Must not advance when Autoplay is disabled and there's no queue")
    }
}
#endif
