import XCTest

// MARK: - SiriShortcutsUITests
//
// UI tests for the Siri Shortcuts deep-link flow implemented in SiriShortcuts.swift.
//
// `OpenYouTubeVideoIntent.perform()` cannot be invoked directly from XCUITest —
// Siri and the Shortcuts app run outside the test process. Instead, these tests
// exercise the exact outcome the intent produces: firing `ipockettube://video/<id>`.
//
// The mechanism: AppEntry reads `--uitesting-deeplink-video=<id>` on first
// `.active` scene phase and calls `browseViewModel.deepLinkedVideo = Video(...)`,
// which is the same code path triggered by `handleOpenURL(_:)` when the real
// intent fires the deep link. This simulates the intent's effect deterministically,
// without a network call to open the URL.
//
// What is tested:
//   1. A valid video ID passed via the launch arg opens PlayerView (`player.titleLabel`).
//   2. An empty video ID does not open the player (guard in consumeDeepLinkFromLaunchArgs).
//   3. The launch arg only fires once — re-backgrounding does not reopen the player.

final class SiriShortcutsUITests: XCTestCase {

    // Known-good video ID used by other regression tests in this suite.
    private static let knownVideoID = "dQw4w9WgXcQ"

    private var app: XCUIApplication!

    // MARK: - Lifecycle

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    override func tearDownWithError() throws {
        app = nil
    }

    // MARK: - Helpers

    private var playerTitleLabel: XCUIElement {
        app.staticTexts["player.titleLabel"].firstMatch
    }

    /// Launches the app with the deep-link launch argument for `videoID`.
    private func launchWithDeepLink(videoID: String) {
        app.launchArguments = ["--uitesting", "--uitesting-disable-tos-player-on-ios", "--uitesting-deeplink-video=\(videoID)"]
        app.launch()
    }

    // MARK: - Tests

    /// Verifies that `--uitesting-deeplink-video=<id>` causes `PlayerView` to
    /// open automatically, reproducing `OpenYouTubeVideoIntent.perform()` firing
    /// `ipockettube://video/<id>` and the app routing it to the player.
    func testDeepLinkFromIntentOpensPlayer() {
        launchWithDeepLink(videoID: Self.knownVideoID)
        XCTAssertTrue(
            playerTitleLabel.waitForExistence(timeout: 15),
            "player.titleLabel should appear when the deep-link launch arg is set — " +
            "PlayerView did not open, indicating the deepLinkedVideo path is broken"
        )
    }

    /// Verifies that an empty video ID in the launch arg is silently ignored and
    /// does NOT open the player — matching the guard in consumeDeepLinkFromLaunchArgs.
    func testEmptyDeepLinkVideoIDIsIgnored() {
        launchWithDeepLink(videoID: "")
        // Give the app a moment to settle before asserting the player is absent.
        _ = app.tabBars.firstMatch.waitForExistence(timeout: 5)
        XCTAssertFalse(
            playerTitleLabel.exists,
            "player.titleLabel should NOT appear for an empty video ID — " +
            "the guard in consumeDeepLinkFromLaunchArgs should have returned early"
        )
    }

    /// Verifies that backgrounding and re-foregrounding the app after the deep
    /// link has already been consumed does not reopen the player a second time.
    ///
    /// `consumeDeepLinkFromLaunchArgs` reads `ProcessInfo.arguments` which is
    /// immutable, but `browseViewModel.deepLinkedVideo` is set to nil after the
    /// player closes — so the re-foreground code path should NOT fire again
    /// because the player is already dismissed.
    func testDeepLinkDoesNotReopenPlayerOnForeground() {
        launchWithDeepLink(videoID: Self.knownVideoID)

        // Wait for the player to open.
        guard playerTitleLabel.waitForExistence(timeout: 15) else {
            XCTFail("Player did not open on deep link launch — precondition for this test failed")
            return
        }

        // Dismiss the player (back gesture or system back).
        let backButton = app.buttons["player.backButton"].firstMatch
        if backButton.waitForExistence(timeout: 3) {
            backButton.tap()
        } else {
            // Fallback: swipe right to dismiss
            app.swipeRight()
        }

        // Background then foreground the app.
        #if os(iOS)
        XCUIDevice.shared.press(.home)
        #endif
        app.activate()

        // The player must NOT reopen — deepLinkedVideo was nil'd after first open.
        Thread.sleep(forTimeInterval: 2)
        XCTAssertFalse(
            playerTitleLabel.exists,
            "player.titleLabel reappeared after re-foregrounding — " +
            "consumeDeepLinkFromLaunchArgs must not fire more than once per session"
        )
    }
}
