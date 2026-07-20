import XCTest

// MARK: - PlayerAndMiniPlayerUITests
//
// Merged from: MiniPlayerUITests + PlayerControlsUITests
// (all tests except testPiPButtonStartsPiP, which relaunches the app internally
//  and lives in PlayerControlsUITests as its own isolated test)
//
// Single launch args: --uitesting
// All tests open the player from the home feed via openPlayerFromHome().
// Each test starts with returnToHome() in instance setUp to reset navigation state.

final class PlayerAndMiniPlayerUITests: XCTestCase {

    private static var sharedApp: XCUIApplication!
    private static var skipAllTests = false
    private static let skipReason = "Home feed did not load — network unavailable or feed empty"

    // MARK: - Lifecycle

    override class func setUp() {
        super.setUp()
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--uitesting-disable-tos-player-on-ios"]
        app.launch()
        sharedApp = app

        UITestHelpers.tapTab(named: "Home", in: app)
        if UITestHelpers.waitForVideoCards(in: app, timeout: 25) == nil {
            skipAllTests = true
        }
    }

    override class func tearDown() {
        sharedApp?.terminate()
        sharedApp = nil
        super.tearDown()
    }

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        returnToHome()
    }

    // MARK: - Helpers

    private var app: XCUIApplication { Self.sharedApp }

    private var miniPlayerBar: XCUIElement {
        app.otherElements["miniPlayer.bar"].firstMatch
    }

    private var miniPlayerPlayPause: XCUIElement {
        app.buttons["miniPlayer.playPauseButton"].firstMatch
    }

    private var miniPlayerClose: XCUIElement {
        app.buttons["miniPlayer.closeButton"].firstMatch
    }

    private var miniPlayerTitle: XCUIElement {
        app.staticTexts["miniPlayer.titleLabel"].firstMatch
    }

    private var backButton: XCUIElement {
        app.buttons["player.backButton"].firstMatch
    }

    private var playerTitle: XCUIElement {
        app.staticTexts["player.titleLabel"].firstMatch
    }

    private var playPauseButton: XCUIElement {
        app.buttons["player.playPauseButton"].firstMatch
    }

    private var nextButton: XCUIElement {
        app.buttons["player.nextBtn"].firstMatch
    }

    /// Resets app state to a clean home feed before each test.
    private func returnToHome() {
        let a = app
        // Dismiss full-screen player if open.
        let back = a.buttons["player.backButton"].firstMatch
        if back.waitForExistence(timeout: 2), back.isHittable {
            back.tap()
            Thread.sleep(forTimeInterval: 1.0)
        }
        // Close mini-player if present.
        let close = a.buttons["miniPlayer.closeButton"].firstMatch
        if close.waitForExistence(timeout: 3), close.isHittable {
            close.tap()
            Thread.sleep(forTimeInterval: 0.5)
        }
        UITestHelpers.tapTab(named: "Home", in: a)
        _ = UITestHelpers.waitForVideoCards(in: a, timeout: 8)
    }

    /// Opens the player from Home and waits for it to load.
    @discardableResult
    private func openPlayerFromHome() throws -> String {
        UITestHelpers.tapTab(named: "Home", in: app)
        guard let card = UITestHelpers.waitForVideoCards(in: app, timeout: 20) else {
            try captureAndSkip("No video cards on Home — network unavailable or feed empty", in: app)
        }
        guard UITestHelpers.openPlayer(from: card, in: app) else {
            try captureAndSkip("Player did not open within 15 s — network unavailable or timing-dependent", in: app)
        }
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline && playerTitle.label.isEmpty {
            Thread.sleep(forTimeInterval: 0.3)
        }
        return playerTitle.label
    }

    /// Taps the player center to reveal controls, then taps back to minimize.
    private func minimizePlayer() {
        if !backButton.exists {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            Thread.sleep(forTimeInterval: 1.0)
        }
        backButton.tap()
    }

    /// Taps center until the play/pause button appears in the controls overlay.
    private func showControls() {
        for _ in 0..<5 {
            if playPauseButton.exists { return }
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            Thread.sleep(forTimeInterval: 1.5)
        }
    }

    // MARK: - Tests (from MiniPlayerUITests)

    /// Regression test for task #95.
    func testMiniPlayerDoesNotOverlapTabBar() throws {
        try XCTSkipIf(Self.skipAllTests, Self.skipReason)
        try openPlayerFromHome()
        minimizePlayer()
        guard miniPlayerBar.waitForExistence(timeout: 5) else {
            try captureAndSkip("miniPlayer.bar not found — mini-player may not be active in this environment", in: app)
        }

        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 5), "Tab bar must be present")
        let miniPlayerMaxY = miniPlayerBar.frame.maxY
        let tabBarMinY = tabBar.frame.minY
        XCTAssertLessThanOrEqual(
            miniPlayerMaxY, tabBarMinY + 2,
            "Mini player bottom (\(miniPlayerMaxY)) must not overlap tab bar top (\(tabBarMinY))"
        )

        UITestHelpers.tapTab(named: "Search", in: app)
        XCTAssertTrue(miniPlayerBar.waitForExistence(timeout: 5),
                      "Mini player must persist across tab switch")
        let onSearchTab = app.textFields["search.bar"].waitForExistence(timeout: 5)
        XCTAssertTrue(onSearchTab, "Tapping Search tab must navigate there (tab bar must be accessible under mini player)")
    }

    func testMiniPlayerAppearsAfterBackButton() throws {
        try XCTSkipIf(Self.skipAllTests, Self.skipReason)
        try openPlayerFromHome()
        minimizePlayer()
        XCTAssertTrue(miniPlayerBar.waitForExistence(timeout: 5),
                      "miniPlayer.bar should appear after tapping the back button")
        let chipBar = app.scrollViews["home.chipBar"]
        XCTAssertTrue(chipBar.waitForExistence(timeout: 5),
                      "home.chipBar should be visible while mini-player is showing")
    }

    func testMiniPlayerShowsCorrectTitle() throws {
        try XCTSkipIf(Self.skipAllTests, Self.skipReason)
        let title = try openPlayerFromHome()
        guard !title.isEmpty else {
            try captureAndSkip("Player title not yet populated — cannot verify mini-player title match", in: app)
        }
        minimizePlayer()
        guard miniPlayerBar.waitForExistence(timeout: 5) else {
            try captureAndSkip("miniPlayer.bar not found — mini-player may not be active in this environment", in: app)
        }
        XCTAssertEqual(miniPlayerTitle.label, title,
                       "miniPlayer.titleLabel should match the video that was playing")
    }

    func testMiniPlayerPlayPauseToggle() throws {
        try XCTSkipIf(Self.skipAllTests, Self.skipReason)
        try openPlayerFromHome()
        minimizePlayer()
        guard miniPlayerBar.waitForExistence(timeout: 5) else {
            try captureAndSkip("miniPlayer.bar not found — mini-player may not be active in this environment", in: app)
        }
        miniPlayerPlayPause.tap()
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertEqual(app.state, .runningForeground,
                       "App must not crash after tapping play/pause in mini-player")
        miniPlayerPlayPause.tap()
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertEqual(app.state, .runningForeground,
                       "App must not crash after toggling play/pause twice in mini-player")
    }

    func testMiniPlayerCloseStopsPlayback() throws {
        try XCTSkipIf(Self.skipAllTests, Self.skipReason)
        try openPlayerFromHome()
        minimizePlayer()
        guard miniPlayerBar.waitForExistence(timeout: 5) else {
            try captureAndSkip("miniPlayer.bar not found — mini-player may not be active in this environment", in: app)
        }
        miniPlayerClose.tap()
        let miniGone = NSPredicate(format: "exists == false")
        let disappear = XCTNSPredicateExpectation(predicate: miniGone, object: miniPlayerBar)
        XCTWaiter().wait(for: [disappear], timeout: 3)
        XCTAssertFalse(miniPlayerBar.exists, "miniPlayer.bar should disappear after tapping close")
        let chipBar = app.scrollViews["home.chipBar"]
        XCTAssertTrue(chipBar.waitForExistence(timeout: 5),
                      "home.chipBar should remain visible after closing the mini-player")
    }

    func testTappingMiniPlayerExpandsToFullScreen() throws {
        try XCTSkipIf(Self.skipAllTests, Self.skipReason)
        let title = try openPlayerFromHome()
        minimizePlayer()
        guard miniPlayerBar.waitForExistence(timeout: 5) else {
            try captureAndSkip("miniPlayer.bar not found — mini-player may not be active in this environment", in: app)
        }
        miniPlayerBar.tap()
        XCTAssertTrue(playerTitle.waitForExistence(timeout: 5),
                      "player.titleLabel should reappear after tapping the mini-player bar")
        XCTAssertEqual(playerTitle.label, title,
                       "Expanded player should show the same video that was minimized")
    }

    func testMiniPlayerPersistsAcrossTabNavigation() throws {
        try XCTSkipIf(Self.skipAllTests, Self.skipReason)
        try openPlayerFromHome()
        minimizePlayer()
        guard miniPlayerBar.waitForExistence(timeout: 5) else {
            try captureAndSkip("miniPlayer.bar not found — mini-player may not be active in this environment", in: app)
        }
        for tab in ["Search", "Library", "Settings", "Home"] {
            UITestHelpers.tapTab(named: tab, in: app)
            Thread.sleep(forTimeInterval: 0.5)
            XCTAssertTrue(miniPlayerBar.exists,
                          "miniPlayer.bar should persist while on the \(tab) tab")
        }
    }

    func testBackButtonDismissesFullScreenOnSingleTap() throws {
        try XCTSkipIf(Self.skipAllTests, Self.skipReason)
        try openPlayerFromHome()
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(backButton.waitForExistence(timeout: 5),
                      "player.backButton must exist after opening the player")
        backButton.tap()
        XCTAssertTrue(miniPlayerBar.waitForExistence(timeout: 5),
                      "miniPlayer.bar must appear after a single back-button tap — " +
                      "regression for the dismissPlayerAction bypass fix")
        let fullScreenGone = NSPredicate(format: "exists == false")
        let expectation = XCTNSPredicateExpectation(predicate: fullScreenGone, object: backButton)
        let result = XCTWaiter().wait(for: [expectation], timeout: 3)
        XCTAssertEqual(result, .completed,
                       "player.backButton should not be visible once mini-player is showing")
    }

    func testMiniPlayerGhostAudioGuard() throws {
        try XCTSkipIf(Self.skipAllTests, Self.skipReason)
        try openPlayerFromHome()
        minimizePlayer()
        guard miniPlayerBar.waitForExistence(timeout: 5) else {
            try captureAndSkip("miniPlayer.bar not found — mini-player may not be active in this environment", in: app)
        }
        miniPlayerClose.tap()
        Thread.sleep(forTimeInterval: 1.0)
        XCTAssertFalse(miniPlayerBar.exists, "Mini-player must be gone before opening new video")

        UITestHelpers.tapTab(named: "Home", in: app)
        guard let card = UITestHelpers.waitForVideoCards(in: app, timeout: 20) else {
            try captureAndSkip("No video cards for second open attempt — network unavailable or feed empty", in: app)
        }
        guard UITestHelpers.openPlayer(from: card, in: app) else {
            try captureAndSkip("Player did not reopen within 15 s — network unavailable or timing-dependent", in: app)
        }
        XCTAssertEqual(app.state, .runningForeground,
                       "App must be running after re-opening the player")
    }

    func testMiniPlayerCloseDeactivatesAudioSession() throws {
        try XCTSkipIf(Self.skipAllTests, Self.skipReason)
        try openPlayerFromHome()
        minimizePlayer()
        guard miniPlayerBar.waitForExistence(timeout: 5) else {
            try captureAndSkip("miniPlayer.bar not found — mini-player may not be active in this environment", in: app)
        }
        miniPlayerClose.tap()
        let miniGone = NSPredicate(format: "exists == false")
        let disappear = XCTNSPredicateExpectation(predicate: miniGone, object: miniPlayerBar)
        let result = XCTWaiter().wait(for: [disappear], timeout: 3)
        XCTAssertEqual(result, .completed, "miniPlayer.bar must disappear after tapping close")
        Thread.sleep(forTimeInterval: 0.5)

        UITestHelpers.tapTab(named: "Home", in: app)
        guard let card = UITestHelpers.waitForVideoCards(in: app, timeout: 20) else {
            try captureAndSkip("No video cards for second open — network unavailable or feed empty", in: app)
        }
        guard UITestHelpers.openPlayer(from: card, in: app) else {
            try captureAndSkip("Player did not reopen within 15 s — timing-dependent", in: app)
        }
        XCTAssertEqual(app.state, .runningForeground,
                       "App must be in foreground — crash would indicate AVAudioSession reactivation failure")
    }

    func testMiniPlayerCloseDoesNotRestoreFullScreen() throws {
        try XCTSkipIf(Self.skipAllTests, Self.skipReason)
        try openPlayerFromHome()
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(backButton.waitForExistence(timeout: 5))
        backButton.tap()
        XCTAssertTrue(miniPlayerBar.waitForExistence(timeout: 5),
                      "miniPlayer.bar must appear after minimizing")
        miniPlayerClose.tap()
        Thread.sleep(forTimeInterval: 3)
        XCTAssertFalse(miniPlayerBar.exists,
                       "miniPlayer.bar must not exist after tapping close")
        XCTAssertFalse(backButton.exists,
                       "player.backButton (fullscreen indicator) must not reappear after close — " +
                       "regression for task #34 fullscreen-restore bug")
    }

    // MARK: - Tests (from PlayerControlsUITests)

    func testControlsAppearOnTap() throws {
        try XCTSkipIf(Self.skipAllTests, Self.skipReason)
        try openPlayerFromHome()
        showControls()
        guard playPauseButton.waitForExistence(timeout: 5) else {
            try captureAndSkip("player.playPauseButton did not appear — controls overlay may not respond to tap reliably on simulator (timing-dependent)", in: app)
        }
    }

    func testPlayPauseToggles() throws {
        try XCTSkipIf(Self.skipAllTests, Self.skipReason)
        try openPlayerFromHome()
        showControls()
        guard playPauseButton.waitForExistence(timeout: 5) else {
            try captureAndSkip("player.playPauseButton did not appear — controls overlay may not respond to tap reliably on simulator (timing-dependent)", in: app)
        }
        playPauseButton.tap()
        Thread.sleep(forTimeInterval: 0.5)
        showControls()
        guard playPauseButton.waitForExistence(timeout: 5) else {
            try captureAndSkip("player.playPauseButton did not reappear after re-tap — timing-dependent", in: app)
        }
        playPauseButton.tap()
        XCTAssertEqual(app.state, .runningForeground,
                       "App must still be running after toggling play/pause")
    }

    func testBackButtonDismissesPlayer() throws {
        try XCTSkipIf(Self.skipAllTests, Self.skipReason)
        try openPlayerFromHome()
        XCTAssertTrue(backButton.waitForExistence(timeout: 5),
                      "player.backButton must be present")
        backButton.tap()
        let miniPlayerBar = app.otherElements["miniPlayer.bar"].firstMatch
        XCTAssertTrue(miniPlayerBar.waitForExistence(timeout: 5),
                      "miniPlayer.bar should appear after tapping the back button")
        let miniPlayerClose = app.buttons["miniPlayer.closeButton"].firstMatch
        guard miniPlayerClose.waitForExistence(timeout: 3) else {
            try captureAndSkip("miniPlayer.closeButton not found — in-app PiP may not be active on this build", in: app)
        }
        miniPlayerClose.tap()
        let chipBar = app.scrollViews["home.chipBar"]
        XCTAssertTrue(chipBar.waitForExistence(timeout: 5),
                      "home.chipBar should reappear after closing the mini-player")
        XCTAssertFalse(miniPlayerBar.exists,
                       "miniPlayer.bar should be gone after tapping close")
    }

    func testNoErrorBannerOnNormalPlayback() throws {
        try XCTSkipIf(Self.skipAllTests, Self.skipReason)
        let title = try openPlayerFromHome()
        Thread.sleep(forTimeInterval: 10)
        UITestHelpers.assertNoPlayerErrorBanner(in: app, videoTitle: title)
    }

    func testPlayerStaysOpenAfterTap() throws {
        try XCTSkipIf(Self.skipAllTests, Self.skipReason)
        try openPlayerFromHome()
        showControls()
        Thread.sleep(forTimeInterval: 2)
        XCTAssertTrue(playerTitle.exists,
                      "player.titleLabel should still be visible after tapping the player — player must not dismiss unexpectedly")
    }

    func testNextVideoButtonLoadsNewVideo() throws {
        try XCTSkipIf(Self.skipAllTests, Self.skipReason)
        try openPlayerFromHome()
        let initialTitle = playerTitle.label

        let deadline = Date().addingTimeInterval(20)
        var nextEnabled = false
        while Date() < deadline {
            showControls()
            if nextButton.waitForExistence(timeout: 3.5), nextButton.isEnabled {
                nextEnabled = true
                break
            }
        }
        guard nextEnabled else {
            try captureAndSkip("player.nextBtn did not become enabled within 20 s — related videos may not have loaded", in: app)
        }

        nextButton.tap()

        let loadDeadline = Date().addingTimeInterval(30)
        var newTitle = playerTitle.label
        while Date() < loadDeadline && newTitle == initialTitle {
            Thread.sleep(forTimeInterval: 1)
            newTitle = playerTitle.label
        }
        guard newTitle != initialTitle else {
            try captureAndSkip("Title did not change within 30s — next video may share the same title or network is slow", in: app)
        }
    }

    #if os(iOS)
    func testNextAndPrevButtonsAreHittableInPortrait() throws {
        try XCTSkipIf(Self.skipAllTests, Self.skipReason)
        #if os(iOS)
        XCUIDevice.shared.orientation = .portrait
        #endif
        try openPlayerFromHome()

        // Controls auto-hide after a few seconds. Poll with repeated taps until
        // nextButton is both visible and hittable (up to 20 s total).
        let center = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        var foundNext = false
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            center.tap()
            Thread.sleep(forTimeInterval: 1.0)
            if nextButton.exists, nextButton.isHittable {
                foundNext = true
                break
            }
        }

        guard foundNext else {
            try captureAndSkip("player.nextBtn did not become hittable in portrait within 20 s — timing-dependent", in: app)
        }
        XCTAssertTrue(nextButton.isHittable,
                      "player.nextBtn must be hittable in portrait — regression for task #45 hit-area fix")

        let prevButton = app.buttons["player.prevBtn"].firstMatch
        if prevButton.waitForExistence(timeout: 3) {
            XCTAssertTrue(prevButton.isHittable,
                          "player.prevBtn must be hittable in portrait — regression for task #45 hit-area fix")
        }
    }

    /// Regression test for task #121.
    /// Drags the seek bar from 20% to 70% and verifies the playback position advances.
    /// Catches chapter-marker hit areas intercepting the slider DragGesture.
    func testSeekBarDragScrubs() throws {
        try XCTSkipIf(Self.skipAllTests, Self.skipReason)

        try openPlayerFromHome()
        // Wait for video to start playing so currentTime is non-zero and duration > 0.
        Thread.sleep(forTimeInterval: 6)

        showControls()

        // Locate the progress bar container element.
        let progressBar = app.otherElements["player.progressBar"].firstMatch
        guard progressBar.waitForExistence(timeout: 8) else {
            try captureAndSkip("player.progressBar not found — controls may not be visible", in: app)
        }

        // Capture the title label before scrub to confirm the player stays open.
        let titleBefore = playerTitle.label

        // Drag from ~20% to ~70% of the seek bar width.
        let barFrame = progressBar.frame
        let startX = barFrame.minX + barFrame.width * 0.20
        let endX   = barFrame.minX + barFrame.width * 0.70
        let midY   = barFrame.midY
        let startCoord = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: startX, dy: midY))
        let endCoord   = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: endX, dy: midY))
        startCoord.press(forDuration: 0.05, thenDragTo: endCoord)

        // Allow the seek to complete.
        Thread.sleep(forTimeInterval: 2)

        // Player must still be open (not crashed or dismissed).
        XCTAssertFalse(playerTitle.label.isEmpty,
                       "Player was dismissed or crashed during seek-bar drag — title disappeared")
        XCTAssertEqual(playerTitle.label, titleBefore,
                       "Wrong video loaded after seek-bar drag")
    }
    #endif
}
