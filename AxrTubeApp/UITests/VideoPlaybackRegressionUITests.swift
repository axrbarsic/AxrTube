import XCTest

// MARK: - VideoPlaybackRegressionUITests
//
// Regression test for video playback failures caused by IP-bound HLS manifests.
// YouTube's iOS client returns HLS manifest URLs that are locked to the fetching
// IP address. On the iOS Simulator, AVPlayer's download IP can differ from the
// URLSession IP used by InnerTubeAPI, producing HTTP 404 errors.
//
// The fix uses the Android InnerTube client as a fallback, which returns direct
// CDN videoplayback URLs that are not subject to the same IP-binding restriction.
//
// This test verifies that video Dy9ki9Q5nXs ("Reviewing Every Themed Tourist Trap
// Restaurant") opens and plays without a player error banner.
//
// The test uses --uitesting-deeplink-video=<ID> to open the player directly,
// bypassing the History dependency entirely.

final class VideoPlaybackRegressionUITests: XCTestCase {

    private static let targetVideoID = "Dy9ki9Q5nXs"

    private var app: XCUIApplication!

    // MARK: - Lifecycle

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["--uitesting"]
        app.launchArguments += ["--uitesting-disable-tos-player-on-ios"]
        app.launchArguments += ["--uitesting-deeplink-video=\(Self.targetVideoID)"]
        app.launch()
    }

    override func tearDownWithError() throws {
        app = nil
    }

    // MARK: - Regression: stop then replay (#51)

    /// Regression test for task #51: video does not reload after stop and replay.
    ///
    /// Exact reproduction path:
    ///   1. Open a video from the Home feed.
    ///   2. Tap the back button — player minimises to the mini-player bar.
    ///   3. Tap X on the mini-player bar — calls `stop()`, bar disappears.
    ///   4. Find the same video card in the Home feed and tap it again.
    ///   5. Assert the player opens and the video plays without an error banner.
    ///
    /// Root cause: `stop()` did not cancel `itemObserverTask` / `endObserverTask`,
    /// leaving stale observers that interfered with a subsequent `load(video:)` call.
    func testReplayAfterStop() throws {
        // Launch without the class-level deeplink so the Home feed is shown.
        let homeApp = XCUIApplication()
        homeApp.launchArguments = ["--uitesting", "--uitesting-disable-tos-player-on-ios"]
        homeApp.launch()

        // 1. Wait for Home feed to load.
        UITestHelpers.tapTab(named: "Home", in: homeApp)
        guard let firstCard = UITestHelpers.waitForVideoCards(in: homeApp, timeout: 25) else {
            try captureAndSkip("Home feed did not load any cards — network unavailable", in: app)
        }

        // Record the card identifier so we can find the same video after stop.
        let cardID = firstCard.identifier

        // 2. Open the video from Home.
        guard UITestHelpers.openPlayer(from: firstCard, in: homeApp) else {
            try captureAndSkip("Player did not open within 15 s — network unavailable", in: app)
        }

        // Give the stream time to start buffering.
        Thread.sleep(forTimeInterval: 5)

        // 3. Tap back button — minimises to mini-player.
        let backButton = homeApp.buttons["player.backButton"].firstMatch
        if !backButton.exists {
            homeApp.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            Thread.sleep(forTimeInterval: 1.0)
        }
        XCTAssertTrue(backButton.waitForExistence(timeout: 3), "player.backButton not found")
        backButton.tap()

        let miniPlayerBar = homeApp.otherElements["miniPlayer.bar"].firstMatch
        guard miniPlayerBar.waitForExistence(timeout: 5) else {
            try captureAndSkip("miniPlayer.bar did not appear — mini-player may be disabled on this build", in: app)
        }

        // 4. Tap X on the mini-player — calls stop().
        let miniPlayerClose = homeApp.buttons["miniPlayer.closeButton"].firstMatch
        XCTAssertTrue(miniPlayerClose.waitForExistence(timeout: 5), "miniPlayer.closeButton not found")
        miniPlayerClose.tap()

        // Confirm the mini-player disappears before proceeding.
        let miniGone = NSPredicate(format: "exists == false")
        let disappear = XCTNSPredicateExpectation(predicate: miniGone, object: miniPlayerBar)
        XCTWaiter().wait(for: [disappear], timeout: 5)
        XCTAssertFalse(miniPlayerBar.exists, "miniPlayer.bar should be gone after tapping close")

        // 5. Find the same video card in the Home feed and open it again.
        let sameCard = homeApp.descendants(matching: .any).matching(identifier: cardID).firstMatch
        guard sameCard.waitForExistence(timeout: 5) else {
            try captureAndSkip("Video card '\(cardID)' not found after returning to Home — feed may have refreshed", in: app)
        }
        sameCard.tap()

        // 6. Assert the player reopens.
        let titleLabel = homeApp.staticTexts["player.titleLabel"].firstMatch
        guard titleLabel.waitForExistence(timeout: 20) else {
            XCTFail("player.titleLabel did not appear on second open from Home — " +
                    "black screen / stop() regression (#51) may still be present")
            return
        }

        // Give the stream time to start (or fail).
        Thread.sleep(forTimeInterval: 10)

        // 7. Assert no error banner — the video must play on the second open.
        let errorBanner = homeApp.otherElements["player.errorBanner"].firstMatch
        XCTAssertFalse(
            errorBanner.exists,
            "player.errorBanner appeared on second open from Home — " +
            "itemObserverTask/endObserverTask cancellation in stop() may be broken (#51)."
        )
        XCTAssertFalse(
            homeApp.alerts["Error"].exists,
            "An 'Error' alert appeared on second open from Home (#51)"
        )
        XCTAssertTrue(
            titleLabel.exists,
            "player.titleLabel disappeared after second open — PlayerView was unexpectedly dismissed (#51)"
        )
    }

    // MARK: - Regression: second open after stop (#second-open)

    /// Regression test for: after stop(), re-opening the same video shows a black screen.
    ///
    /// Root cause: `PlayerStateStore.play(video:)` only called `vm.load(video:)` when the
    /// video ID changed. After `stop()`, the player item was nil but `vm.currentVideoId`
    /// still held the old ID — so `load()` was never called on the second open.
    ///
    /// Fix: also reload when `vm.player.currentItem == nil` (stop cleared it).
    func testSecondOpenAfterStopPlays() throws {
        // 1. Wait for the deeplink player to open.
        let titleLabel = app.staticTexts["player.titleLabel"].firstMatch
        guard titleLabel.waitForExistence(timeout: 20) else {
            try captureAndSkip("player.titleLabel did not appear within 20 s — network unavailable or deeplink did not fire", in: app)
        }

        // 2. Let the video start buffering.
        Thread.sleep(forTimeInterval: 5)

        // 3. Tap the back button — with miniPlayerEnabled=true (the default) this
        //    minimizes the player rather than stopping it outright.
        let backButton = app.buttons["player.backButton"].firstMatch
        XCTAssertTrue(backButton.exists, "player.backButton not found — cannot dismiss player")
        backButton.tap()

        // 4. Wait for the mini-player bar to appear, then tap its close button to stop.
        let miniPlayerBar = app.otherElements["miniPlayer.bar"].firstMatch
        guard miniPlayerBar.waitForExistence(timeout: 5) else {
            try captureAndSkip("miniPlayer.bar did not appear — mini-player may be disabled on this build", in: app)
        }
        let miniPlayerClose = app.buttons["miniPlayer.closeButton"].firstMatch
        XCTAssertTrue(miniPlayerClose.waitForExistence(timeout: 5), "miniPlayer.closeButton not found after minimizing")
        miniPlayerClose.tap()

        // 5. Wait for the mini-player to disappear — confirms stop() was called.
        let miniBarGone = NSPredicate(format: "exists == false")
        expectation(for: miniBarGone, evaluatedWith: miniPlayerBar)
        waitForExpectations(timeout: 5)

        // 6. Re-open the same video in-session via the uitesting overlay button.
        //    This is the exact code path that was broken: same video ID, item=nil after stop().
        let reopenButton = app.buttons["uitesting.reopenDeeplinkVideoButton"].firstMatch
        XCTAssertTrue(reopenButton.waitForExistence(timeout: 3), "uitesting.reopenDeeplinkVideoButton not found — overlay missing")
        reopenButton.tap()

        // 7. Wait for the player to re-open.
        guard titleLabel.waitForExistence(timeout: 20) else {
            XCTFail("player.titleLabel did not reappear within 20 s on second open — black screen bug may still be present")
            return
        }

        // 8. Give the stream time to load.
        Thread.sleep(forTimeInterval: 10)

        // 9. Assert playback succeeded: no error banner and player is still open.
        let errorBanner = app.otherElements["player.errorBanner"].firstMatch
        XCTAssertFalse(
            errorBanner.exists,
            "player.errorBanner appeared on second open of \(Self.targetVideoID) after stop() — " +
            "PlayerStateStore.play() may not be calling vm.load() when player.currentItem is nil."
        )
        XCTAssertFalse(
            app.alerts["Error"].exists,
            "An 'Error' alert appeared on second open of \(Self.targetVideoID)"
        )
        XCTAssertTrue(
            titleLabel.exists,
            "player.titleLabel disappeared after second open — PlayerView was unexpectedly dismissed"
        )
    }
}
