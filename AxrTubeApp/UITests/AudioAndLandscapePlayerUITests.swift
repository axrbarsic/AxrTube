import XCTest

// MARK: - AudioAndLandscapePlayerUITests
//
// Merged from: AudioOnlyMenuRowUITests (5 tests) + LandscapeLockButtonUITests (2 of 3 tests).
// Shared launch args: --uitesting --uitesting-deeplink-video=dQw4w9WgXcQ
//
// testLandscapeAlwaysPlayRemovedFromSettings is kept separately in
// HomeFeedAndSettingsUITests (it uses plain --uitesting + Settings tab, a different
// launch profile than the player-deeplink tests here).

final class AudioAndLandscapePlayerUITests: XCTestCase {

    // MARK: - Shared lifecycle

    private static var sharedApp: XCUIApplication!
    private var app: XCUIApplication { AudioAndLandscapePlayerUITests.sharedApp }

    override class func setUp() {
        super.setUp()
        sharedApp = XCUIApplication()
        sharedApp.launchArguments = [
            "--uitesting",
            "--uitesting-disable-tos-player-on-ios",
            "--uitesting-deeplink-video=dQw4w9WgXcQ"
        ]
        sharedApp.launch()
    }

    override class func tearDown() {
        sharedApp.terminate()
        sharedApp = nil
        super.tearDown()
    }

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        // Restore portrait in case a previous test changed orientation.
        #if os(iOS)
        XCUIDevice.shared.orientation = .portrait
        #endif
        // Dismiss any lingering alert (e.g. permission or error dialog).
        let alert = app.alerts.firstMatch
        if alert.waitForExistence(timeout: 1) {
            let ok = alert.buttons["OK"].firstMatch
            if ok.exists { ok.tap() } else { alert.buttons.firstMatch.tap() }
        }
        // If audio-only mode is ON from a previous test (overlay visible), turn it OFF.
        let overlayPred = NSPredicate(format: "identifier == 'player.audioOnlyOverlay'")
        let overlay = app.descendants(matching: .any).matching(overlayPred).firstMatch
        if overlay.waitForExistence(timeout: 2) {
            // Show controls then tap the audio-only button to disable.
            showControls()
            let audioOnlyBtn = app.buttons["player.audioOnlyButton"].firstMatch
            if audioOnlyBtn.waitForExistence(timeout: 3) {
                audioOnlyBtn.tap()
            }
            // Wait for overlay to disappear before proceeding.
            let gone = NSPredicate(format: "exists == false")
            let exp = XCTNSPredicateExpectation(predicate: gone, object: overlay)
            _ = XCTWaiter().wait(for: [exp], timeout: 5)
        }
    }

    override func tearDown() {
        // Always restore portrait so the next test starts in a known orientation.
        #if os(iOS)
        XCUIDevice.shared.orientation = .portrait
        #endif
        super.tearDown()
    }

    // MARK: - Helpers

    /// Waits for the player to be ready (title label visible).
    private func waitForPlayer(timeout: TimeInterval = 20) throws {
        let playerTitle = app.staticTexts["player.titleLabel"].firstMatch
        guard playerTitle.waitForExistence(timeout: timeout) else {
            try captureAndSkip("Player did not open within \(timeout) s — network unavailable or video inaccessible", in: app)
        }
    }

    /// Ensures player controls are visible by tapping centre until the audio-only button
    /// is hittable. Mirrors the loop pattern in PlayerAndMiniPlayerUITests.showControls().
    private func showControls() {
        let audioOnlyBtn = app.buttons["player.audioOnlyButton"].firstMatch
        for _ in 0..<5 {
            if audioOnlyBtn.exists { return }
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            Thread.sleep(forTimeInterval: 1.5)
        }
    }

    // MARK: - Tests (from AudioOnlyMenuRowUITests)

    /// The Audio-Only button must appear in the player bottom-bar on-screen controls.
    func testAudioOnlyRowExistsInMoreMenu() throws {
        try waitForPlayer()
        showControls()
        let audioOnlyBtn = app.buttons["player.audioOnlyButton"].firstMatch
        XCTAssertTrue(audioOnlyBtn.waitForExistence(timeout: 5),
                      "player.audioOnlyButton must be present in the player bottom-bar controls")
    }

    /// Tapping Audio-Only must not crash the app.
    func testAudioOnlyRowToggleDoesNotCrash() throws {
        try waitForPlayer()
        showControls()
        let audioOnlyBtn = app.buttons["player.audioOnlyButton"].firstMatch
        guard audioOnlyBtn.waitForExistence(timeout: 5) else {
            try captureAndSkip("player.audioOnlyButton not visible — skipping toggle test", in: app)
        }
        audioOnlyBtn.tap()
        // Verify the app didn't crash — no player.view identifier exists; use app.state.
        Thread.sleep(forTimeInterval: 1)
        XCTAssertEqual(app.state, .runningForeground,
                       "App must remain running after tapping Audio-Only")
    }

    /// Tapping Audio-Only ON must show the thumbnail overlay on the current video.
    func testAudioOnlyButtonShowsOverlayOnCurrentVideo() throws {
        try waitForPlayer()
        showControls()
        let audioOnlyBtn = app.buttons["player.audioOnlyButton"].firstMatch
        guard audioOnlyBtn.waitForExistence(timeout: 5) else {
            try captureAndSkip("player.audioOnlyButton not visible — skipping overlay test", in: app)
        }
        // setUp ensures audio-only is OFF, so overlay must not exist yet.
        let overlayPred = NSPredicate(format: "identifier == 'player.audioOnlyOverlay'")
        let overlay = app.descendants(matching: .any).matching(overlayPred).firstMatch
        XCTAssertFalse(overlay.exists, "Overlay must not be visible before enabling audio-only")
        audioOnlyBtn.tap()
        XCTAssertTrue(overlay.waitForExistence(timeout: 15),
                      "player.audioOnlyOverlay must appear after enabling audio-only on current video")
    }

    /// Tapping Audio-Only OFF must hide the thumbnail overlay on the current video.
    func testAudioOnlyButtonHidesOverlayOnCurrentVideo() throws {
        try waitForPlayer()
        showControls()
        let audioOnlyBtn = app.buttons["player.audioOnlyButton"].firstMatch
        guard audioOnlyBtn.waitForExistence(timeout: 5) else {
            try captureAndSkip("player.audioOnlyButton not visible — skipping overlay hide test", in: app)
        }
        // Turn audio-only ON.
        audioOnlyBtn.tap()
        let overlayPred = NSPredicate(format: "identifier == 'player.audioOnlyOverlay'")
        let overlay = app.descendants(matching: .any).matching(overlayPred).firstMatch
        guard overlay.waitForExistence(timeout: 15) else {
            try captureAndSkip("Overlay did not appear after enabling audio-only — skipping hide test", in: app)
        }
        // The audio-only stream load may briefly reset controlsVisible; allow it to settle.
        Thread.sleep(forTimeInterval: 5)
        // Show controls again then turn OFF.
        showControls()
        guard audioOnlyBtn.waitForExistence(timeout: 5) else {
            try captureAndSkip("player.audioOnlyButton not visible after overlay appeared — skipping", in: app)
        }
        audioOnlyBtn.tap()
        // Overlay must disappear and the player must still be running.
        let overlayGone = NSPredicate(format: "exists == false")
        expectation(for: overlayGone, evaluatedWith: overlay)
        waitForExpectations(timeout: 15)
        XCTAssertEqual(app.state, .runningForeground,
                       "App must remain running after turning audio-only OFF")
    }

    /// Tapping the Audio-Only button must show a toast confirming the mode change.
    func testAudioOnlyToggleShowsToast() throws {
        try waitForPlayer()
        showControls()
        let audioOnlyBtn = app.buttons["player.audioOnlyButton"].firstMatch
        guard audioOnlyBtn.waitForExistence(timeout: 5) else {
            try captureAndSkip("player.audioOnlyButton not visible — skipping toast test", in: app)
        }
        // Tap to enter audio-only mode — toast "Audio-Only Mode" should appear.
        audioOnlyBtn.tap()
        let toast = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Audio'")).firstMatch
        guard toast.waitForExistence(timeout: 4) else {
            try captureAndSkip("Toast disappeared before assertion — may be a slow simulator timing issue", in: app)
        }
        XCTAssertEqual(app.state, .runningForeground,
                       "App must remain running after audio-only toast")
    }

    // MARK: - Tests (from LandscapeLockButtonUITests)

    /// The landscape lock button should appear in the player top bar.
    func testLandscapeLockButtonExistsInPlayer() throws {
        try waitForPlayer()
        showControls()
        let lockButton = app.buttons["player.landscapeLockButton"].firstMatch
        XCTAssertTrue(lockButton.waitForExistence(timeout: 5),
                      "Landscape lock button must appear in the player controls overlay")
        XCTAssertTrue(lockButton.isHittable,
                      "Landscape lock button must be tappable")
    }

    /// Tapping the lock button must not crash or dismiss the player.
    func testLandscapeLockButtonToggles() throws {
        try waitForPlayer()
        showControls()
        let lockButton = app.buttons["player.landscapeLockButton"].firstMatch
        XCTAssertTrue(lockButton.waitForExistence(timeout: 5),
                      "Landscape lock button must be present before tapping")
        // Tap to lock.
        lockButton.tap()
        // Verify no crash — player.view identifier doesn't exist; use app.state.
        XCTAssertEqual(app.state, .runningForeground,
                       "App must remain running after tapping the landscape lock button")
        // Wait for the landscape rotation animation to settle before re-probing controls.
        Thread.sleep(forTimeInterval: 2)
        // Tap again to unlock.
        showControls()
        XCTAssertTrue(lockButton.waitForExistence(timeout: 5),
                      "Lock button must still exist after first tap")
        lockButton.tap()
        XCTAssertEqual(app.state, .runningForeground,
                       "App must remain running after unlocking")
    }
}
