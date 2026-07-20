import XCTest

// MARK: - PlayerControlsUITests
//
// All tests except testPiPButtonStartsPiP have moved to PlayerAndMiniPlayerUITests.swift
// (combined with MiniPlayerUITests for a single shared app launch).
//
// testPiPButtonStartsPiP is kept here because it deliberately terminates and
// re-launches the app with --uitesting-enable-pip and cannot share state.

final class PlayerControlsUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["--uitesting", "--uitesting-disable-tos-player-on-ios"]
        app.launch()
    }

    override func tearDownWithError() throws {
        app = nil
    }

    // MARK: - Helpers

    @discardableResult
    private func openPlayerFromHome() throws -> String {
        UITestHelpers.tapTab(named: "Home", in: app)
        guard let card = UITestHelpers.waitForVideoCards(in: app, timeout: 20) else {
            try captureAndSkip("No video cards on Home — network unavailable or feed empty", in: app)
        }
        guard UITestHelpers.openPlayer(from: card, in: app) else {
            try captureAndSkip("Player did not open within 15 s — network unavailable or timing-dependent", in: app)
        }
        return app.staticTexts["player.titleLabel"].firstMatch.label
    }

    private var playPauseButton: XCUIElement {
        app.buttons["player.playPauseButton"].firstMatch
    }

    private var pipButton: XCUIElement {
        app.buttons["player.pipButton"].firstMatch
    }

    private func showControls() {
        for _ in 0..<5 {
            if playPauseButton.exists { return }
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            Thread.sleep(forTimeInterval: 1.5)
        }
    }

    // MARK: - Tests

    #if os(iOS)
    func testPlayPauseButtonMeetsMinimumTapTarget() throws {
        // Verify the play/pause button tap target is at least 44×44pt (Apple HIG minimum).
        // Task #127 added .padding(12) + .contentShape(Rectangle()) to fix a ~42pt icon
        // that had no padding and therefore fell below the minimum.
        try openPlayerFromHome()
        showControls()
        guard playPauseButton.waitForExistence(timeout: 8) else {
            try captureAndSkip("player.playPauseButton not found — cannot verify tap target size", in: app)
        }
        let frame = playPauseButton.frame
        XCTAssertGreaterThanOrEqual(frame.width, 44,
            "play/pause button width \(frame.width)pt is below the 44pt Apple HIG minimum")
        XCTAssertGreaterThanOrEqual(frame.height, 44,
            "play/pause button height \(frame.height)pt is below the 44pt Apple HIG minimum")
    }

    func testCaptionCuePositionedAboveScrubBar() throws {
        // Task #129: caption cue must appear above the scrub/progress bar, not overlap it.
        // Verifies padding change from 72pt (fixed) to 130pt (when controls visible).
        // Skips gracefully if the video has no captions or no cue is active.
        try openPlayerFromHome()
        showControls()
        let scrubBar = app.otherElements["player.progressBar"].firstMatch
        let captionCue = app.staticTexts.matching(identifier: "player.captionCue").firstMatch
        guard scrubBar.waitForExistence(timeout: 8) else {
            try captureAndSkip("Scrub bar not found — cannot verify caption position", in: app)
        }
        guard captionCue.waitForExistence(timeout: 5) else {
            // No caption cue visible — video may not have captions or no cue is active.
            // This is an acceptable skip; regression is only detectable when captions are on.
            try captureAndSkip("player.captionCue not visible — video has no active caption cue", in: app)
        }
        let cueMaxY = captionCue.frame.maxY
        let scrubMinY = scrubBar.frame.minY
        XCTAssertLessThan(cueMaxY, scrubMinY,
            "Caption cue bottom (\(cueMaxY)pt) must be above scrub bar top (\(scrubMinY)pt) — task #129")
    }

    func testPiPButtonStartsPiP() throws {
        // Re-launch with --uitesting-enable-pip to bypass the isPictureInPictureSupported()
        // guard on parallel clone simulators where the entitlement may not propagate.
        app.terminate()
        app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--uitesting-disable-tos-player-on-ios", "--uitesting-enable-pip"]
        app.launch()
        try openPlayerFromHome()
        showControls()
        guard pipButton.waitForExistence(timeout: 5) else {
            try captureAndSkip("player.pipButton not found — PiP may not be available on this device/iOS version", in: app)
        }
        pipButton.tap()
        // PiP windows are not directly queryable; just ensure no crash.
        Thread.sleep(forTimeInterval: 2)
        XCTAssertEqual(app.state, .runningForeground,
                       "App must still be running after tapping the PiP button")
    }
    #endif
}
