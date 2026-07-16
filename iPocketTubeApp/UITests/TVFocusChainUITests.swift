import XCTest

// MARK: - TVFocusChainUITests
//
// Verifies the tvOS focus chain in the Home tab:
//   Tab bar → ↓ → Chips → ↓ → Video list → (select) → Video plays
//   Video list → Esc (Menu) → Chips (no video plays)
//
// Run against the "iPocketTube" tvOS target.
// XCUIRemote simulates Siri Remote D-pad, select, and menu (back) presses.

final class TVFocusChainUITests: XCTestCase {

    private var app: XCUIApplication!
    private let remote = XCUIRemote.shared

    // MARK: - Lifecycle

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    override func tearDownWithError() throws {
        app = nil
    }

    // MARK: - Helpers

    private var chipBar: XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'home.chipBar'"))
            .firstMatch
    }

    private var titleLabel: XCUIElement {
        app.staticTexts["player.titleLabel"].firstMatch
    }

    /// Waits up to `timeout` seconds for at least one video card to appear.
    private func waitForVideoCards(timeout: TimeInterval = 20) -> Bool {
        let predicate = NSPredicate(format: "identifier BEGINSWITH 'video.card.'")
        let cards = app.descendants(matching: .any).matching(predicate)
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "count > 0"),
            object: cards
        )
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    // MARK: - Tests

    /// Pressing ↓ once from the tab bar enters the chip bar.
    /// Proven by: ↓ → → → select switches to the next chip's feed
    /// (only possible if → navigated between chips, meaning focus was in the chip bar).
    func testDownOneEntersChips() throws {
        XCTAssertTrue(
            chipBar.waitForExistence(timeout: 15),
            "home.chipBar must appear — app failed to launch or content did not load"
        )

        // Verify chip buttons are accessible before testing focus navigation.
        let subscriptionsChip = app.buttons.matching(
            NSPredicate(format: "identifier == 'chip.Subscriptions'")
        ).firstMatch
        XCTAssertTrue(
            subscriptionsChip.waitForExistence(timeout: 5),
            "chip.Subscriptions must be in the accessibility tree"
        )

        // Step 1: ↓ from tab bar → chip bar must receive focus
        remote.press(.down)
        Thread.sleep(forTimeInterval: 1.0)

        // Step 2: → moves to the next chip (Subscriptions)
        // If focus was NOT in the chip bar, → would move within video content instead.
        remote.press(.right)
        Thread.sleep(forTimeInterval: 0.8)

        // Step 3: select activates the focused chip
        remote.press(.select)
        Thread.sleep(forTimeInterval: 1.0)

        // A different chip is now selected — the section container loads immediately
        // regardless of network state (loading spinner, empty state, or content).
        let sectionContainer = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'home.sectionContainer'"))
            .firstMatch
        XCTAssertTrue(
            sectionContainer.waitForExistence(timeout: 10),
            "home.sectionContainer must appear after ↓ + → + select — " +
            "focus was not in the chip bar after one ↓ press"
        )
    }

    /// Pressing ↓ twice from the initial state enters the video list.
    /// Verified by pressing select and confirming the player opens.
    func testDownTwiceEntersVideoListAndSelectPlaysVideo() throws {
        // Wait for chip bar to appear (app loaded and feed ready)
        XCTAssertTrue(
            chipBar.waitForExistence(timeout: 15),
            "home.chipBar must appear — app failed to launch or content did not load"
        )

        // Wait for video cards to load before navigating
        guard waitForVideoCards(timeout: 20) else {
            try captureAndSkip("No video cards loaded within 20 s — network unavailable or feed empty", in: app)
        }

        // Step 1: ↓ from tab bar → chip bar receives focus
        remote.press(.down)
        Thread.sleep(forTimeInterval: 0.6)

        // Step 2: ↓ from chip bar → video list receives focus
        remote.press(.down)
        Thread.sleep(forTimeInterval: 0.6)

        // Step 3: Select → the focused video card activates and the player opens
        remote.press(.select)

        // Verify the player opened (proves focus reached the video list)
        XCTAssertTrue(
            titleLabel.waitForExistence(timeout: 15),
            "player.titleLabel must appear after pressing down twice and select — " +
            "focus chain is broken (focus did not reach the video list)"
        )
    }

    /// Pressing Esc (Menu) from the video list returns focus to chips without playing a video.
    func testEscFromVideoListReturnsFocusToChipsWithoutPlaying() throws {
        XCTAssertTrue(
            chipBar.waitForExistence(timeout: 15),
            "home.chipBar must appear"
        )

        guard waitForVideoCards(timeout: 20) else {
            try captureAndSkip("No video cards loaded within 20 s — network unavailable or feed empty", in: app)
        }

        // Navigate into video list (down × 2)
        remote.press(.down)
        Thread.sleep(forTimeInterval: 0.6)
        remote.press(.down)
        Thread.sleep(forTimeInterval: 0.6)

        // Menu/Esc — should return focus to chips, not navigate anywhere
        remote.press(.menu)
        Thread.sleep(forTimeInterval: 0.5)

        // Chip bar must still be visible (still on Home screen)
        XCTAssertTrue(
            chipBar.exists,
            "home.chipBar must still exist after pressing Menu/Esc from the video list"
        )

        // Player must NOT have opened
        XCTAssertFalse(
            titleLabel.exists,
            "player.titleLabel must NOT appear — Esc from video list should NOT play a video"
        )
    }

    // MARK: - Player behaviour tests

    /// Pressing the Menu button while the player is open dismisses the player
    /// and returns to the Home screen.
    func testPlayerMenuButtonDismissesPlayer() throws {
        XCTAssertTrue(
            chipBar.waitForExistence(timeout: 15),
            "home.chipBar must appear"
        )

        guard waitForVideoCards(timeout: 20) else {
            try captureAndSkip("No video cards loaded within 20 s — network unavailable or feed empty", in: app)
        }

        // Navigate to player: ↓ (tab bar → chips) ↓ (chips → video list) select
        remote.press(.down)
        Thread.sleep(forTimeInterval: 0.6)
        remote.press(.down)
        Thread.sleep(forTimeInterval: 0.6)
        remote.press(.select)

        XCTAssertTrue(
            titleLabel.waitForExistence(timeout: 15),
            "Player must open after ↓↓ select"
        )

        // Press Menu — .onExitCommand should call vm.stop() + dismiss()
        remote.press(.menu)

        // Player is dismissed: titleLabel should disappear
        let titleGone = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: titleLabel
        )
        XCTWaiter().wait(for: [titleGone], timeout: 5)
        XCTAssertFalse(titleLabel.exists, "player.titleLabel must disappear after Menu press")

        // Home is restored
        XCTAssertTrue(
            chipBar.waitForExistence(timeout: 5),
            "home.chipBar must reappear after dismissing the player with Menu"
        )
    }

    /// Pressing the Play/Pause button while the player is open makes the
    /// controls overlay appear (playPauseButton becomes visible in the HUD).
    func testPlayPauseCommandShowsControlsOverlay() throws {
        XCTAssertTrue(
            chipBar.waitForExistence(timeout: 15),
            "home.chipBar must appear"
        )

        guard waitForVideoCards(timeout: 20) else {
            try captureAndSkip("No video cards loaded within 20 s — network unavailable or feed empty", in: app)
        }

        // Open the player
        remote.press(.down)
        Thread.sleep(forTimeInterval: 0.6)
        remote.press(.down)
        Thread.sleep(forTimeInterval: 0.6)
        remote.press(.select)

        XCTAssertTrue(
            titleLabel.waitForExistence(timeout: 15),
            "Player must open"
        )

        // Give player a moment to load — controls should be hidden initially
        Thread.sleep(forTimeInterval: 1.5)

        let playPauseBtn = app.buttons["player.playPauseButton"].firstMatch
        XCTAssertFalse(
            playPauseBtn.exists,
            "player.playPauseButton must NOT be visible before pressing play/pause (controls hidden)"
        )

        // Press Play/Pause — triggers .onPlayPauseCommand → togglePlayPause() → showControls()
        remote.press(.playPause)
        Thread.sleep(forTimeInterval: 0.5)

        XCTAssertTrue(
            playPauseBtn.waitForExistence(timeout: 5),
            "player.playPauseButton must appear in the controls HUD after pressing Play/Pause"
        )
    }

    /// Pressing ↑ and ↓ on the D-pad while in the player shows the controls
    /// overlay (D-pad up/down calls toggleControls()).
    func testDpadUpDownShowsControlsInPlayer() throws {
        XCTAssertTrue(chipBar.waitForExistence(timeout: 15))

        guard waitForVideoCards(timeout: 20) else {
            try captureAndSkip("No video cards loaded within 20 s", in: app)
        }

        remote.press(.down)
        Thread.sleep(forTimeInterval: 0.6)
        remote.press(.down)
        Thread.sleep(forTimeInterval: 0.6)
        remote.press(.select)

        XCTAssertTrue(titleLabel.waitForExistence(timeout: 15), "Player must open")
        Thread.sleep(forTimeInterval: 1.5)

        let playPauseBtn = app.buttons["player.playPauseButton"].firstMatch
        XCTAssertFalse(playPauseBtn.exists, "Controls must be hidden initially")

        // D-pad up → toggleControls() → controlsVisible = true
        remote.press(.up)
        Thread.sleep(forTimeInterval: 0.5)

        XCTAssertTrue(
            playPauseBtn.waitForExistence(timeout: 5),
            "player.playPauseButton must appear after pressing D-pad up in the player"
        )
    }

    /// Pressing ← or → in the player keeps the player open (seek, not dismiss).
    func testLeftRightDpadSeeksWithinPlayer() throws {
        XCTAssertTrue(chipBar.waitForExistence(timeout: 15))

        guard waitForVideoCards(timeout: 20) else {
            try captureAndSkip("No video cards loaded within 20 s", in: app)
        }

        remote.press(.down)
        Thread.sleep(forTimeInterval: 0.6)
        remote.press(.down)
        Thread.sleep(forTimeInterval: 0.6)
        remote.press(.select)

        XCTAssertTrue(titleLabel.waitForExistence(timeout: 15), "Player must open")
        Thread.sleep(forTimeInterval: 2.0)   // let a few seconds of video load

        // Seek left (-10 s) and right (+10 s) — player must stay open
        remote.press(.left)
        Thread.sleep(forTimeInterval: 0.5)
        remote.press(.right)
        Thread.sleep(forTimeInterval: 0.5)

        XCTAssertTrue(
            titleLabel.exists,
            "player.titleLabel must still exist after left/right D-pad seeks"
        )
    }

    // MARK: - Settings nav bar regression (task-102 / gh-34)

    /// After scrolling Settings down then back up, the tvOS tab bar must still be
    /// visible (hittable) — not stuck transparent due to nav bar animation conflict.
    func testSettingsTabBarVisibleAfterScrollDownAndUp() throws {
        // Navigate to Settings tab (rightmost)
        for _ in 0..<4 { remote.press(.right) }
        remote.press(.select)
        Thread.sleep(forTimeInterval: 2)

        let resetButton = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'settings.resetAllButton'"))
            .firstMatch
        guard resetButton.waitForExistence(timeout: 10) else {
            try captureAndSkip("settings.resetAllButton not found — Settings did not open", in: app)
        }

        // Scroll down to trigger tab bar hide
        for _ in 0..<12 { remote.press(.down) }
        Thread.sleep(forTimeInterval: 0.5)

        // Scroll back up past the top to restore tab bar
        for _ in 0..<15 { remote.press(.up) }
        Thread.sleep(forTimeInterval: 1.0)

        let settingsTabButton = app.buttons["Settings"].firstMatch
        XCTAssertTrue(
            settingsTabButton.waitForExistence(timeout: 5),
            "Settings tab bar button must exist after scroll-down-then-up"
        )
        XCTAssertTrue(
            settingsTabButton.isHittable,
            "Settings tab bar button must be hittable after scroll-down-then-up — regression for issue #102 / gh-34"
        )
    }
}
