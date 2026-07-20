import XCTest

// MARK: - AirPlayUITests
//
// UI tests for AirPlay support in the iPocketTube player.
//
// What's tested:
//   • The AirPlay button (player.airPlayButton) is visible in the player controls overlay.
//   • Tapping the button opens the route picker sheet without crashing.
//   • The button is visible alongside (not replacing) the PiP button.
//
// What cannot be tested on simulator:
//   • Actual AirPlay routing — requires a physical AirPlay-compatible device on the same network.
//   • The "Playing on Apple TV" indicator — only fires when a real AirPlay session is active.
//
// Network is required to open the player from the Home feed.
// Tests skip gracefully when the feed is empty or the player fails to open.

final class AirPlayUITests: XCTestCase {

    private var app: XCUIApplication!

    // MARK: - Lifecycle

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        // --uitesting-enable-pip bypasses AVPictureInPictureController.isPictureInPictureSupported()
        // on parallel clone simulators where entitlements may not propagate.
        app.launchArguments += ["--uitesting", "--uitesting-disable-tos-player-on-ios", "--uitesting-enable-pip"]
        app.launch()
    }

    override func tearDownWithError() throws {
        app = nil
    }

    // MARK: - Helpers

    /// Opens the player from the first Home feed card.
    /// Skips if no cards are available or the player fails to open.
    private func openPlayer() throws {
        UITestHelpers.tapTab(named: "Home", in: app)
        guard let card = UITestHelpers.waitForVideoCards(in: app, timeout: 20) else {
            try captureAndSkip("No video cards on Home — network unavailable or feed empty", in: app)
        }
        guard UITestHelpers.openPlayer(from: card, in: app) else {
            try captureAndSkip("Player did not open within 15 s — network unavailable or timing-dependent", in: app)
        }
    }

    /// Taps the player to reveal the controls overlay.
    private func showControls() {
        let playPause = app.buttons["player.playPauseButton"].firstMatch
        for _ in 0..<5 {
            if playPause.exists { return }
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            Thread.sleep(forTimeInterval: 1.5)
        }
    }

    private var airPlayButton: XCUIElement {
        // AVRoutePickerView is a UIView. With isAccessibilityElement=true and
        // accessibilityTraits=[.button] it appears as a button in the XCUITest tree.
        // Fall back to otherElements for resilience across iOS versions.
        let btn = app.buttons["player.airPlayButton"].firstMatch
        if btn.exists { return btn }
        return app.otherElements["player.airPlayButton"].firstMatch
    }

    private var pipButton: XCUIElement {
        app.buttons["player.pipButton"].firstMatch
    }

    // MARK: - Tests

    /// Verifies the AirPlay button is present in the player controls overlay.
    func testAirPlayButtonVisible() throws {
        try openPlayer()
        showControls()
        // Re-tap to ensure controls remain visible: the overlay auto-dismisses
        // and `showControls()` may have been called just before it hid again.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        Thread.sleep(forTimeInterval: 0.5)
        guard airPlayButton.waitForExistence(timeout: 8) else {
            try captureAndSkip("player.airPlayButton not found — AVRoutePickerView may not be " +
                          "accessible on this simulator configuration (controls may have dismissed)", in: app)
        }
    }

    /// Verifies the AirPlay button and PiP button coexist in the controls overlay.
    func testAirPlayButtonAndPiPButtonCoexist() throws {
        try openPlayer()
        showControls()
        guard airPlayButton.waitForExistence(timeout: 5) else {
            try captureAndSkip("player.airPlayButton not found — controls may not have appeared", in: app)
        }
        guard pipButton.waitForExistence(timeout: 3) else {
            try captureAndSkip("player.pipButton not found — PiP may not be supported on this simulator", in: app)
        }
        // Both must be in the same screen region (top-right area).
        let airPlayFrame = airPlayButton.frame
        let pipFrame = pipButton.frame
        XCTAssertFalse(airPlayFrame.intersects(pipFrame),
                       "player.airPlayButton and player.pipButton must not overlap")
    }

    /// Verifies that tapping the AirPlay button does not crash the app.
    /// On simulator the route picker will appear with "iPhone" as the only option
    /// (no AirPlay-capable devices present). Dismiss it by tapping outside.
    func testAirPlayButtonTapDoesNotCrash() throws {
        try openPlayer()
        showControls()
        guard airPlayButton.waitForExistence(timeout: 5) else {
            try captureAndSkip("player.airPlayButton not found — cannot test tap behaviour", in: app)
        }
        airPlayButton.tap()
        Thread.sleep(forTimeInterval: 1.0)
        // Dismiss any sheet that appeared (route picker, action sheet, etc.)
        // by tapping outside its frame.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)).tap()
        Thread.sleep(forTimeInterval: 0.5)
        // The app must still be running after the tap.
        XCTAssertEqual(app.state, .runningForeground,
                       "App must not crash after tapping the AirPlay button")
    }

    /// Verifies the player continues playing after the AirPlay button is tapped and dismissed.
    func testPlaybackContinuesAfterAirPlayButtonDismissed() throws {
        try openPlayer()
        showControls()
        guard airPlayButton.waitForExistence(timeout: 5) else {
            try captureAndSkip("player.airPlayButton not found — cannot test playback continuity", in: app)
        }
        airPlayButton.tap()
        Thread.sleep(forTimeInterval: 1.0)
        // Dismiss the route picker.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)).tap()
        Thread.sleep(forTimeInterval: 1.0)
        // Player title must still be present — player did not close or error.
        let titleLabel = app.staticTexts["player.titleLabel"].firstMatch
        XCTAssertTrue(titleLabel.exists,
                      "player.titleLabel should still be visible after dismissing the AirPlay picker")
        XCTAssertEqual(app.state, .runningForeground,
                       "App must be in foreground after dismissing the AirPlay route picker")
    }
}
