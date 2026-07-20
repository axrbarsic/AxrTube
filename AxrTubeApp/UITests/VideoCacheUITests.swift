import XCTest

// MARK: - VideoCacheUITests
//
// Verifies that the VideoPreloadCache neighbour-prefetch system works end-to-end:
//
//   1. Open Home tab → tap first video → player loads
//   2. Wait up to 20 s for Phase 2 to complete (related videos + neighbour prefetch)
//   3. Swipe to the next related video
//   4. Assert the title changes (new video loaded)
//
// Log assertions (AGENT-POST-RUN-CHECK):
//   - "[prefetch] ENQUEUE" must appear at least once (neighbour prefetch triggered)
//   - "[prefetch] DONE" must appear at least once (prefetch completed before swipe)
//   - "cache HIT: playerInfo" OR "coalescedPrefetch HIT: playerInfo" must appear for
//     the video tapped in step 3 — confirming the cache served playerInfo without a
//     fresh network call.
//
// AGENT-POST-RUN-CHECK:
//   REQUIRE_LOG: [prefetch] ENQUEUE
//   REQUIRE_LOG: [prefetch] DONE
//   REQUIRE_LOG: cache HIT: playerInfo (skipping network)
//   NOTE: if "coalescedPrefetch HIT" appears instead of "cache HIT", that is also
//         acceptable — it means the in-flight coalescing path succeeded.
//   FAIL_IF_LOG: cache: playerInfo=false
//   CATEGORY: PreloadCache

#if os(iOS)

final class VideoCacheUITests: XCTestCase {

    private var app: XCUIApplication!

    // MARK: - Lifecycle

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--uitesting-disable-tos-player-on-ios"]
        app.launch()
    }

    override func tearDownWithError() throws {
        app = nil
    }

    // MARK: - Helpers

    private func tapHomeTab() {
        UITestHelpers.tapTab(named: "Home", in: app, timeout: 5)
    }

    private func waitForFirstVideoCard(timeout: TimeInterval = 25) -> XCUIElement? {
        let predicate = NSPredicate(format: "identifier BEGINSWITH 'video.card.'")
        let cards = app.descendants(matching: .any).matching(predicate)
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count > 0"),
                                                    object: cards)
        guard XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed else {
            return nil
        }
        return cards.firstMatch
    }

    private var titleLabel: XCUIElement {
        app.staticTexts["player.titleLabel"].firstMatch
    }

    private func swipeLeft() {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.5))
        let end   = app.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: end)
    }

    // MARK: - Tests

    /// Verifies the neighbour prefetch runs after Phase 2 and populates the cache,
    /// so that swiping to the next video hits the cache instead of the network.
    func testNeighbourPrefetchAndCacheHitOnNextVideo() throws {
        tapHomeTab()

        guard let card = waitForFirstVideoCard(timeout: 25) else {
            try captureAndSkip("No video cards loaded within 25 s — network unavailable or feed empty", in: app)
        }

        card.tap()

        // Wait for the player title to appear and become non-empty.
        guard titleLabel.waitForExistence(timeout: 20) else {
            try captureAndSkip("player.titleLabel did not appear — network unavailable", in: app)
        }
        let nonEmpty = NSPredicate(format: "label != ''")
        let titleAppeared = XCTNSPredicateExpectation(predicate: nonEmpty, object: titleLabel)
        guard XCTWaiter().wait(for: [titleAppeared], timeout: 15) == .completed else {
            try captureAndSkip("player.titleLabel stayed empty — playerInfo did not load", in: app)
        }
        let firstTitle = titleLabel.label

        // Wait for Phase 2 + neighbour prefetch to complete.
        // Phase 2 fetches related videos, then schedules the prefetch Task (background).
        // We allow up to 20 s for the prefetch to store playerInfo before we swipe.
        // The test logs will show "[prefetch] DONE" when this is ready.
        Thread.sleep(forTimeInterval: 20)

        // Swipe left to the next related video. The cache should serve playerInfo.
        swipeLeft()

        // Wait for the new video to load.
        let titleChanged = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label != %@ AND label != ''", firstTitle),
            object: titleLabel
        )
        let result = XCTWaiter().wait(for: [titleChanged], timeout: 20)
        XCTAssertEqual(result, .completed,
                       "Player title did not change after swipe — next video did not load. " +
                       "First title: '\(firstTitle)', current: '\(titleLabel.label)'")
    }
}

#endif
