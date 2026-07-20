import XCTest

// AGENT-POST-RUN-CHECK: ui-tests-with-logs
//
// After every run of this file, extract device/app logs and inspect.
//
// LEGITIMATE skip:
//   - "More menu did not appear — network unavailable or video inaccessible"
//     Device log should show: network error or timeout in [loadAsync].
//
// BUG skip (must fix before closing):
//   - Any other skip reason indicates a regression.
//
// Log events to verify for #217 (controls-visible → row absent):
//   ✓ shouldShowQualityInMoreMenu returned false (no log line needed — absence of row is the assertion)
//   ✓ [PlayerView] --uitesting-show-controls launch arg detected — showing controls
//   ✓ cache: playerInfo=true (confirms video loaded)
//
// Log events to verify for #217 (controls-hidden → row present):
//   ✓ More menu scroll view appeared
//   ✓ cache: playerInfo=true (confirms video loaded)
//
// RED FLAGS in device log:
//   - controlsVisible never set to true → --uitesting-show-controls arg not consumed
//   - player.moreMenu.qualityRow exists when controls visible → #217 regression
final class PlayerMoreMenuDuplicationUITests: XCTestCase {

    // MARK: - Helpers

    private func launchApp(showControls: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        var args: [String] = [
            "--uitesting",
            "--uitesting-disable-tos-player-on-ios",
            "--uitesting-deeplink-video=dQw4w9WgXcQ",
            "--uitesting-open-more-menu"
        ]
        if showControls { args.append("--uitesting-show-controls") }
        app.launchArguments = args
        #if os(iOS)
        XCUIDevice.shared.orientation = .portrait
        #endif
        app.launch()
        return app
    }

    // MARK: - Tests

    /// When pills are visible (`controlsVisible == true`) the Quality row must
    /// not appear in the overflow menu — it is already accessible via the pill.
    func testQualityRowAbsentFromMoreMenuWhenControlsVisible() throws {
        let app = launchApp(showControls: true)
        defer { app.terminate() }

        let menu = app.scrollViews["player.moreMenu.scrollView"].firstMatch
        guard menu.waitForExistence(timeout: 20) else {
            try captureAndSkip("More menu did not appear — network unavailable or video inaccessible", in: app)
        }

        // Give the menu a moment to fully render all rows.
        _ = app.buttons["player.moreMenu.cancel"].firstMatch.waitForExistence(timeout: 5)

        XCTAssertFalse(
            app.buttons["player.moreMenu.qualityRow"].firstMatch.exists,
            "Quality row must NOT appear in the overflow menu when fullscreen pills are visible (task #217)"
        )
    }

    /// When controls are hidden (`controlsVisible == false`) the Quality row
    /// must appear in the overflow menu so the user can still access quality settings.
    func testQualityRowPresentInMoreMenuWhenControlsHidden() throws {
        let app = launchApp(showControls: false)
        defer { app.terminate() }

        let menu = app.scrollViews["player.moreMenu.scrollView"].firstMatch
        guard menu.waitForExistence(timeout: 20) else {
            try captureAndSkip("More menu did not appear — network unavailable or video inaccessible", in: app)
        }

        // Give the menu a moment to fully render all rows.
        _ = app.buttons["player.moreMenu.cancel"].firstMatch.waitForExistence(timeout: 5)

        // Quality row must be present when controls are hidden (no pills visible).
        XCTAssertTrue(
            app.buttons["player.moreMenu.qualityRow"].firstMatch.waitForExistence(timeout: 5),
            "Quality row must appear in the overflow menu when fullscreen pills are hidden (task #217)"
        )
    }
}
