import XCTest

// MARK: - iPocketTubeShareExtensionUITests
//
// UI tests for the Share Extension integration.
//
// The Share Extension runs in a separate OS process, so XCUITest cannot drive
// ShareViewController directly. Instead, the two code paths it exercises are
// tested through launch arguments that AppEntry understands:
//
//   --uitesting-deeplink-video=<id>
//       Simulates the URL-scheme path: the Share Extension fires
//       `ipockettube://video/<id>` via the responder chain, which AppEntry handles
//       in `handleOpenURL(_:)`. The launch arg exercises the same code path by
//       calling `UIApplication.shared.open(deepLink)` on first `.active`.
//
//   --uitesting-pending-video=<id>
//       Simulates the App Group fallback path: `ShareViewController` writes
//       `pendingVideoID` to `UserDefaults(suiteName: appGroup)` before launching
//       the app. AppEntry reads and clears the value in `consumePendingVideoID()`
//       on every `.active` scene-phase transition. The launch arg exercises the
//       same `browseViewModel.deepLinkedVideo` assignment without touching
//       UserDefaults (which the test process cannot reach across app-group boundaries).
//
// Both paths ultimately set `browseViewModel.deepLinkedVideo`, which triggers
// `RootView`'s `.fullScreenCover(item:)` to present `PlayerView`. The observable
// assertion target is the always-visible `player.titleLabel` accessibility ID.
//
// Network dependency: the player opens with an empty title stub and resolves the
// real title over InnerTube. Tests that only assert presence of `player.titleLabel`
// (not its text value) pass offline. Tests that assert a non-empty title use
// `XCTSkip` when the network is unavailable.

private let kTestVideoID = "dQw4w9WgXcQ" // Rick Astley — publicly available

final class iPocketTubeShareExtensionUITests: XCTestCase {

    private var app: XCUIApplication!

    // MARK: - Lifecycle

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        app = nil
    }

    // MARK: - Helpers

    /// Launches the app with the given extra arguments.
    private func launch(extraArgs: [String] = []) {
        app = XCUIApplication()
        // These tests assert on AVPlayer-pipeline accessibility IDs (player.titleLabel,
        // player.backButton). TOS (IFrame/WKWebView) is the default iOS player as of the
        // PlayerRouter refactor and uses a different ID namespace (tosPlayer.*), so
        // disable it to keep exercising the AVPlayer-based deep-link/pending-video paths.
        app.launchArguments = ["--uitesting-disable-tos-player-on-ios"] + extraArgs
        app.launch()
    }

    /// Waits for `player.titleLabel` to appear within `timeout`.
    /// Returns `true` if it appeared, `false` otherwise.
    @discardableResult
    private func waitForPlayer(timeout: TimeInterval = 20) -> Bool {
        app.staticTexts["player.titleLabel"].firstMatch.waitForExistence(timeout: timeout)
    }

    /// Dismisses the player by tapping the back button.
    private func dismissPlayer() {
        let backButton = app.buttons["player.backButton"].firstMatch
        if backButton.waitForExistence(timeout: 5) {
            backButton.tap()
        }
    }

    // MARK: - Tests

    /// Verifies the deeplink URL-scheme path: the player opens when the app is
    /// launched with `--uitesting-deeplink-video`.
    func testDeeplinkOpensPlayer() throws {
        launch(extraArgs: ["--uitesting-deeplink-video=\(kTestVideoID)"])
        XCTAssertTrue(waitForPlayer(), "player.titleLabel did not appear — deeplink URL-scheme path failed")
        UITestHelpers.assertNoPlayerErrorBanner(in: app)
    }

    /// Verifies that InnerTube resolves a non-empty title for the deep-linked video.
    /// Skipped when the network is unavailable (title stays empty).
    func testDeeplinkPlayerTitleIsPopulated() throws {
        launch(extraArgs: ["--uitesting-deeplink-video=\(kTestVideoID)"])

        let titleLabel = app.staticTexts["player.titleLabel"].firstMatch
        guard titleLabel.waitForExistence(timeout: 20) else {
            XCTFail("player.titleLabel did not appear within 20 s — network may be unavailable")
            return
        }

        // Give InnerTube time to resolve the title (initial stub is "").
        let titlePopulated = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label != ''"),
            object: titleLabel
        )
        guard XCTWaiter().wait(for: [titlePopulated], timeout: 15) == .completed else {
            XCTFail("Title did not populate within 15 s — network may be unavailable")
            return
        }

        XCTAssertFalse(titleLabel.label.isEmpty, "player.titleLabel is empty after deeplink open")
    }

    /// Verifies the App Group fallback path: the player opens when the app is
    /// launched with `--uitesting-pending-video` (mirrors `consumePendingVideoID()`).
    func testPendingVideoIDConsumedOnForeground() throws {
        launch(extraArgs: ["--uitesting-pending-video=\(kTestVideoID)"])
        XCTAssertTrue(waitForPlayer(), "player.titleLabel did not appear — App Group pending-video path failed")
        UITestHelpers.assertNoPlayerErrorBanner(in: app)
    }

    /// Verifies the pending deeplink is consumed exactly once.
    /// After dismissing the player and re-foregrounding, the player must NOT reopen.
    func testDeeplinkNotConsumedTwice() throws {
        launch(extraArgs: ["--uitesting-deeplink-video=\(kTestVideoID)"])

        guard waitForPlayer() else {
            XCTFail("player.titleLabel did not appear — network may be unavailable")
            return
        }

        // Dismiss the player so the home screen is visible again.
        dismissPlayer()

        // Background the app, then re-foreground it.
        #if os(iOS)
        XCUIDevice.shared.press(.home)
        #endif
        app.activate()

        // Allow a brief window — if the player reappears the test fails.
        let playerAfterReforeground = app.staticTexts["player.titleLabel"].firstMatch
        XCTAssertFalse(
            playerAfterReforeground.waitForExistence(timeout: 5),
            "player.titleLabel reappeared after re-foregrounding — deeplink was consumed more than once"
        )
    }

    /// Verifies that an empty video ID in the launch argument does NOT open the player.
    func testDeeplinkWithEmptyVideoIDDoesNotOpenPlayer() {
        launch(extraArgs: ["--uitesting-deeplink-video="])

        let playerLabel = app.staticTexts["player.titleLabel"].firstMatch
        XCTAssertFalse(
            playerLabel.waitForExistence(timeout: 5),
            "player.titleLabel appeared for an empty video ID — guard in consumeDeepLinkFromLaunchArgs failed"
        )
    }

    /// Verifies that a pending video with an empty ID does NOT open the player.
    func testPendingVideoWithEmptyIDDoesNotOpenPlayer() {
        launch(extraArgs: ["--uitesting-pending-video="])

        let playerLabel = app.staticTexts["player.titleLabel"].firstMatch
        XCTAssertFalse(
            playerLabel.waitForExistence(timeout: 5),
            "player.titleLabel appeared for an empty pending video ID — guard in consumePendingVideoFromLaunchArgs failed"
        )
    }
}
