#if !os(tvOS)
import XCTest
import iPocketTubeCore
@testable import iPocketTube

@MainActor
final class TOSPlayerViewModelCancelTests: XCTestCase {

    func testCancelPreventsLateSponsorTaskMutation() async throws {
        let vm = TOSPlayerViewModel(videoId: "test_cancel_sponsor", api: InnerTubeAPI())

        vm.sponsorTask = Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if !Task.isCancelled {
                vm.sponsorSegments = [SponsorSegment(start: 0, end: 10, category: .sponsor)]
            }
        }

        try await Task.sleep(nanoseconds: 50_000_000)
        vm.cancel()

        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(vm.sponsorSegments.isEmpty,
                      "sponsorSegments must not be mutated after cancel() — a013be1c regression")
    }

    func testCancelPreventsLateNavigationTaskMutation() async throws {
        let vm = TOSPlayerViewModel(videoId: "test_cancel_nav", api: InnerTubeAPI())
        let fakeVideo = Video(id: "fake_v1", title: "Fake", channelTitle: "Channel")

        vm.navigationTask = Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if !Task.isCancelled {
                vm.relatedVideos = [fakeVideo]
            }
        }

        try await Task.sleep(nanoseconds: 50_000_000)
        vm.cancel()

        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(vm.relatedVideos.isEmpty,
                      "relatedVideos must not be mutated after cancel() — a013be1c regression")
    }

    func testCancelIsIdempotent() {
        let vm = TOSPlayerViewModel(videoId: "test_idempotent", api: InnerTubeAPI())
        vm.cancel()
        vm.cancel()
    }
}
#endif
