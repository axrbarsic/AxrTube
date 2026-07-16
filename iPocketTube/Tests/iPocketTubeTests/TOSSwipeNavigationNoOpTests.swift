#if !os(tvOS)
import XCTest
import iPocketTubeCore
@testable import iPocketTube

// Tests that TOSSwipeNavigationOverlay can be always-enabled (no isEnabled gate)
// because the ViewModel handlers no-op gracefully when navigation is unavailable.
// See #263: the previous isEnabled: vm.hasNext || vm.hasPrevious gate disabled the
// gesture before fetchRelatedVideos() completed, making swipes unresponsive on load.

@MainActor
final class TOSSwipeNavigationNoOpTests: XCTestCase {

    func testPlayNextIsNoOpWhenRelatedVideosEmpty() {
        let vm = TOSPlayerViewModel(videoId: "test_noswipe_next", api: InnerTubeAPI())
        var didCallPlayNext = false
        vm.onPlayNext = { _ in didCallPlayNext = true }
        // relatedVideos is empty by default — playNext must not fire onPlayNext
        vm.playNext()
        XCTAssertFalse(didCallPlayNext, "playNext() must no-op when relatedVideos is empty — safe for always-enabled overlay (#263)")
    }

    func testPlayPreviousIsNoOpWhenHasPreviousFalse() {
        let vm = TOSPlayerViewModel(videoId: "test_noswipe_prev", api: InnerTubeAPI())
        var didCallPlayPrevious = false
        vm.onPlayPrevious = { didCallPlayPrevious = true }
        // hasPrevious defaults to false — playPrevious must not fire onPlayPrevious
        vm.playPrevious()
        XCTAssertFalse(didCallPlayPrevious, "playPrevious() must no-op when hasPrevious=false — safe for always-enabled overlay (#263)")
    }
}
#endif
