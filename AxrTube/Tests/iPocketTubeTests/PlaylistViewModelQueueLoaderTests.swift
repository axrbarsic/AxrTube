import Foundation
import Testing
@testable import iPocketTubeCore

// MARK: - PlaylistViewModelQueueLoaderTests
//
// Verifies the QueuedPlaylistLoader seam introduced in task #60 (Finding 2).
// Uses a mock loader so PlaylistViewModel's queue path can be exercised
// without depending on CurrentQueueStore or any network calls.

// MARK: - Mock helpers

private struct MockQueueLoader: QueuedPlaylistLoader {
    let stubbedVideos: [Video]?
    let expectedPlaylistId: String

    func loadQueuedVideos(for playlistId: String) async -> [Video]? {
        guard playlistId == expectedPlaylistId else { return nil }
        return stubbedVideos
    }
}

private func makeVideo(id: String) -> Video {
    Video(id: id, title: "Video \(id)", channelTitle: "Channel")
}

// MARK: - Tests

@Suite("PlaylistViewModel QueuedPlaylistLoader seam")
@MainActor
struct PlaylistViewModelQueueLoaderTests {

    @Test("Uses queue loader videos when loader returns non-nil")
    func usesQueueLoaderVideos() async throws {
        let queueVideos = [makeVideo(id: "aaa"), makeVideo(id: "bbb")]
        let loader = MockQueueLoader(
            stubbedVideos: queueVideos,
            expectedPlaylistId: "QUEUE_PLAYLIST"
        )
        let vm = PlaylistViewModel(
            api: MockInnerTubeAPI(),
            queueLoader: loader
        )

        vm.load(playlistId: "QUEUE_PLAYLIST")

        // Poll until the async Task inside load() completes.
        let deadline = Date().addingTimeInterval(2)
        while vm.videos.isEmpty && Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }

        #expect(vm.videos.count == 2)
        #expect(vm.videos.first?.id == "aaa")
    }

    @Test("Loader returning nil falls through to API path (no crash)")
    func loaderReturningNilFallsThrough() async {
        let loader = MockQueueLoader(
            stubbedVideos: nil,
            expectedPlaylistId: "QUEUE_PLAYLIST"
        )
        let vm = PlaylistViewModel(
            api: MockInnerTubeAPI(),
            queueLoader: loader
        )
        // A non-queue playlist ID — loader returns nil, so API path is taken.
        // MockInnerTubeAPI throws, so videos stays empty, but no crash.
        vm.load(playlistId: "PLsomeOtherPlaylist")
        // No assertion needed — this test verifies the seam doesn't crash on nil.
        #expect(vm.videos.isEmpty)
    }

    @Test("CurrentQueuePlaylistLoader returns nil for non-queue playlist ID")
    func currentQueueLoaderRejectsNonQueueId() async {
        let loader = CurrentQueuePlaylistLoader()
        let result = await loader.loadQueuedVideos(for: "PLsomeRandomPlaylist")
        #expect(result == nil)
    }
}
