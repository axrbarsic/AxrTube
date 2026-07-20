#if os(iOS)
import XCTest
import iPocketTubeCore
@testable import iPocketTube

@MainActor
final class TOSPlayerStateStoreTests: XCTestCase {
    func testStop_SetsVMToNilAndPresentationHidden() {
        let store = TOSPlayerStateStore()
        let video = Video(id: "testVideoId", title: "Test", channelTitle: "Test Channel")
        let api = InnerTubeAPI()

        store.play(video: video, api: api)
        XCTAssertNotNil(store.vm)

        store.stop()
        XCTAssertNil(store.vm)
        XCTAssertEqual(store.presentation, .hidden)
        XCTAssertNil(store.currentVideo)
    }

    func testStop_IsIdempotent() {
        let store = TOSPlayerStateStore()
        let video = Video(id: "testVideoId", title: "Test", channelTitle: "Test Channel")
        let api = InnerTubeAPI()

        store.play(video: video, api: api)
        store.stop()
        store.stop() // must not crash when vm is already nil
        XCTAssertNil(store.vm)
    }
}
#endif
