import Testing
@testable import iPocketTubeCore

// MARK: - NextVideoPrefetchTests
//
// Verifies the priority ordering and queue-store navigation logic that
// `prefetchQueueVideo(at:)` relies on (task #218).
//
// The actual `VideoPreloadCache.prefetch()` network calls cannot be tested in
// isolation, but the contract they depend on is fully testable:
//  - `.immediate` priority is higher than `.speculative` (next video jumps the queue)
//  - `CurrentQueueStore.videoAt(index:)` returns the right video for a given index
//  - Queue exhaustion returns nil cleanly

@Suite("Next-video prefetch — task #218", .serialized)
struct NextVideoPrefetchTests {

    // MARK: - Priority ordering

    @Test("immediate priority is higher than speculative")
    func immediatePriorityHigherThanSpeculative() {
        #expect(PrefetchPriority.immediate > PrefetchPriority.speculative)
    }

    @Test("immediate priority is higher than visible")
    func immediatePriorityHigherThanVisible() {
        #expect(PrefetchPriority.immediate > PrefetchPriority.visible)
    }

    @Test("speculative is the lowest priority tier")
    func speculativeIsLowest() {
        for tier in PrefetchPriority.allCases where tier != .speculative {
            #expect(tier > .speculative)
        }
    }

    // MARK: - CurrentQueueStore navigation

    @Test("videoAt returns next video for a two-video queue")
    func videoAtReturnsNextVideo() async {
        let videoA = Video(id: "aaaaaaaaaa1", title: "Video A", channelTitle: "Chan")
            .withPlaylistId(CurrentQueueStore.playlistID, index: 0)
        let videoB = Video(id: "bbbbbbbbbb2", title: "Video B", channelTitle: "Chan")
            .withPlaylistId(CurrentQueueStore.playlistID, index: 1)

        await CurrentQueueStore.shared.replaceAll(with: [videoA, videoB])

        let next = await CurrentQueueStore.shared.videoAt(index: 1)
        #expect(next?.id == "bbbbbbbbbb2", "videoAt(1) should return Video B")

        await CurrentQueueStore.shared.clear()
    }

    @Test("videoAt returns nil past the end of the queue")
    func videoAtReturnsNilPastEnd() async {
        let only = Video(id: "onlyvideoid1", title: "Only", channelTitle: "Chan")
            .withPlaylistId(CurrentQueueStore.playlistID, index: 0)

        await CurrentQueueStore.shared.replaceAll(with: [only])

        let past = await CurrentQueueStore.shared.videoAt(index: 1)
        #expect(past == nil, "videoAt past the last index should return nil — no crash or unwrap")

        await CurrentQueueStore.shared.clear()
    }

    @Test("videoAt(index+2) returns the video after next for a three-video queue")
    func videoAtTwoBeyondCurrentReturnsThird() async {
        let a = Video(id: "aaaaaaaaaa1", title: "A", channelTitle: "C")
            .withPlaylistId(CurrentQueueStore.playlistID, index: 0)
        let b = Video(id: "bbbbbbbbbb2", title: "B", channelTitle: "C")
            .withPlaylistId(CurrentQueueStore.playlistID, index: 1)
        let c = Video(id: "cccccccccc3", title: "C", channelTitle: "C")
            .withPlaylistId(CurrentQueueStore.playlistID, index: 2)

        await CurrentQueueStore.shared.replaceAll(with: [a, b, c])

        // When current is index 0, prefetchQueueVideo(at: 2) should warm up C.
        let afterNext = await CurrentQueueStore.shared.videoAt(index: 2)
        #expect(afterNext?.id == "cccccccccc3", "videoAt(2) should return Video C")

        await CurrentQueueStore.shared.clear()
    }
}

// MARK: - Video helper

private extension Video {
    /// Returns a copy of the video with playlistId and playlistIndex set.
    func withPlaylistId(_ playlistId: String, index: Int) -> Video {
        var v = self
        v.playlistId = playlistId
        v.playlistIndex = index
        return v
    }
}
