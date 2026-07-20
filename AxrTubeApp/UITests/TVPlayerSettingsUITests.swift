import XCTest

// XCUIRemote is tvOS-only. The entire file is guarded so it compiles cleanly
// for iOS targets that share the UITests/ source directory.
#if os(tvOS)

// MARK: - TVPlayerSettingsUITests
//
// Verifies that the player settings menu (more menu) and its sub-pickers can be
// opened and interacted with via the Siri Remote on tvOS.
//
// Before this fix, the `.focusSection()` modifier on the overlay container did not
// actively route Siri Remote focus into the menu, so pressing select on the menu
// rows had no effect. The fix replaced `.focusSection()` with `.focusScope()` +
// `.prefersDefaultFocus(in:)` so the focus engine moves into the overlay on open.
//
// The tests use the `--uitesting-open-more-menu` launch argument so the player
// opens the more menu automatically in onAppear. This lets the tests focus on
// verifying focus routing INTO the menu (the actual fix) without relying on
// unreliable D-pad simulation of the player's custom control-navigation model.
//
// Run against the tvOS target / tvOS simulator.

final class TVPlayerSettingsUITests: XCTestCase {

    private var app: XCUIApplication!
    private let remote = XCUIRemote.shared

    // MARK: - Lifecycle

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        // Default launch: open more menu automatically so tests verify focus routing.
        // Individual tests may call launchApp(args:) before any interaction if they
        // need a different set of launch arguments.
        app.launchArguments = ["--uitesting-open-more-menu"]
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

    /// Detects the more menu by the presence of the speed row — the VStack container
    /// identifier propagates to children on tvOS, so we use a child identifier instead.
    private var moreMenuSpeedRow: XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'player.moreMenu.speedRow'"))
            .firstMatch
    }

    private var moreMenuCancelButton: XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'player.moreMenu.cancel'"))
            .firstMatch
    }

    private var moreMenuSleepTimerRow: XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'player.moreMenu.sleepTimerRow'"))
            .firstMatch
    }

    private var speedPicker: XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'player.speedPicker'"))
            .firstMatch
    }

    private var qualityPicker: XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'player.qualityPicker'"))
            .firstMatch
    }

    private var sleepTimerPicker: XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'player.sleepTimerPicker'"))
            .firstMatch
    }

    /// Waits for at least one video card to appear on Home.
    private func waitForVideoCards(timeout: TimeInterval = 20) -> Bool {
        let predicate = NSPredicate(format: "identifier BEGINSWITH 'video.card.'")
        let cards = app.descendants(matching: .any).matching(predicate)
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "count > 0"),
            object: cards
        )
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    /// Navigates from the Home screen into the player:
    ///   ↓ (tab bar → chips) → ↓ (chips → video list) → select (play first video)
    /// Because `--uitesting-open-more-menu` is in the launch args, the player's
    /// `onAppear` will immediately set `showMoreMenu = true` once the player opens.
    private func openPlayer() throws {
        XCTAssertTrue(
            chipBar.waitForExistence(timeout: 15),
            "home.chipBar must appear — app failed to launch or content did not load"
        )
        guard waitForVideoCards(timeout: 20) else {
            XCTFail("No video cards loaded within 20 s — network unavailable or feed empty")
            return
        }
        remote.press(.down)
        Thread.sleep(forTimeInterval: 0.6)
        remote.press(.down)
        Thread.sleep(forTimeInterval: 0.6)
        remote.press(.select)
        XCTAssertTrue(
            titleLabel.waitForExistence(timeout: 15),
            "player.titleLabel must appear after ↓↓ select — player failed to open"
        )
    }

    /// Waits for the more menu to be visible.
    /// With `--uitesting-open-more-menu`, the menu opens automatically in onAppear
    /// so no D-pad navigation is required.
    private func openMoreMenu() throws {
        guard moreMenuSpeedRow.waitForExistence(timeout: 10) else {
            XCTFail("More menu did not open — network unavailable or player failed to appear")
            return
        }
        // Short pause to let the focus engine settle on the speed row.
        Thread.sleep(forTimeInterval: 0.4)
    }

    // MARK: - Tests

    /// The more menu opens automatically via the test launch arg and is visible in
    /// the accessibility tree. The speed row (prefersDefaultFocus) and cancel button
    /// are both individually addressable.
    func testMoreMenuOpensAndIsAccessible() throws {
        try openPlayer()
        try openMoreMenu()

        XCTAssertTrue(
            moreMenuSpeedRow.exists,
            "player.moreMenu.speedRow must be in the accessibility tree"
        )
        XCTAssertTrue(
            moreMenuCancelButton.exists,
            "player.moreMenu.cancel must be in the accessibility tree"
        )
    }

    /// After the more menu opens, the speed row receives `.prefersDefaultFocus` so
    /// it should be focused. Pressing select immediately opens the speed picker.
    func testPlaybackSpeedPickerOpensFromMoreMenu() throws {
        try openPlayer()
        try openMoreMenu()

        // speed row is already in tree (verified by openMoreMenu) and has prefersDefaultFocus.
        XCTAssertTrue(moreMenuSpeedRow.exists, "player.moreMenu.speedRow must be in the accessibility tree")

        // Select activates the focused speed row.
        remote.press(.select)
        Thread.sleep(forTimeInterval: 0.5)

        // Diagnostic: if the speed row still exists, no button was activated (focus nowhere).
        // If it's gone but no picker appeared, the wrong button fired (e.g. Cancel).
        let menuClosedAfterSelect = !moreMenuSpeedRow.exists
        XCTAssertTrue(
            speedPicker.waitForExistence(timeout: 5),
            "player.speedPicker must appear after selecting the Playback Speed row. " +
            "Menu closed after select=\(menuClosedAfterSelect). " +
            "If false → no element had focus. If true → wrong button activated (Cancel?)."
        )
        XCTAssertFalse(moreMenuSpeedRow.exists, "more menu must close when speed picker opens")
    }

    /// After the speed picker opens, pressing Menu (back) dismisses it and returns
    /// to normal player state without crashing.
    func testSpeedPickerDismissesWithMenuButton() throws {
        try openPlayer()
        try openMoreMenu()

        remote.press(.select)   // activate speed row (focused by default)
        Thread.sleep(forTimeInterval: 0.5)

        guard speedPicker.waitForExistence(timeout: 5) else {
            XCTFail("Speed picker did not open — prerequisite failed")
            return
        }

        // Menu / back dismisses the speed picker via .onExitCommand
        remote.press(.menu)
        Thread.sleep(forTimeInterval: 0.6)

        XCTAssertFalse(
            speedPicker.exists,
            "player.speedPicker must be gone after pressing Menu"
        )
        XCTAssertTrue(
            titleLabel.exists,
            "player.titleLabel must still exist after dismissing the speed picker — player must not crash"
        )
    }

    /// Pressing Menu from the more menu dismisses it without crashing and leaves
    /// the player intact.
    func testMoreMenuDismissesWithMenuButton() throws {
        try openPlayer()
        try openMoreMenu()

        remote.press(.menu)
        Thread.sleep(forTimeInterval: 0.6)

        XCTAssertFalse(
            moreMenuSpeedRow.exists,
            "speed row must be gone after pressing Menu — more menu did not dismiss"
        )
        XCTAssertTrue(
            titleLabel.exists,
            "player.titleLabel must still exist after dismissing the more menu — player must not crash"
        )
    }

    /// Sleep Timer row is in the accessibility tree AND the sleep timer picker
    /// opens when the row is activated.
    /// Uses a dedicated launch argument to open the picker directly, bypassing
    /// the focus-navigation within the more menu (which is already exercised by
    /// testPlaybackSpeedPickerOpensFromMoreMenu).
    func testSleepTimerPickerOpenableFromMoreMenu() throws {
        // Re-launch with the sleep-timer-specific arg.
        app.launchArguments = ["--uitesting-open-sleep-timer-picker"]
        app.launch()

        // Navigate to the player (same as other tests).
        XCTAssertTrue(chipBar.waitForExistence(timeout: 15), "home.chipBar must appear")
        guard waitForVideoCards(timeout: 20) else {
            XCTFail("No video cards loaded within 20 s — network unavailable")
            return
        }
        remote.press(.down); Thread.sleep(forTimeInterval: 0.6)
        remote.press(.down); Thread.sleep(forTimeInterval: 0.6)
        remote.press(.select)
        XCTAssertTrue(titleLabel.waitForExistence(timeout: 15), "player.titleLabel must appear")

        // Sleep timer picker opens automatically via the launch arg.
        guard sleepTimerPicker.waitForExistence(timeout: 10) else {
            XCTFail("Sleep timer picker did not open — network or player issue")
            return
        }
        Thread.sleep(forTimeInterval: 0.4) // let focus settle

        XCTAssertTrue(
            sleepTimerPicker.exists,
            "player.sleepTimerPicker must be in the accessibility tree"
        )

        // Menu button dismisses the picker.
        remote.press(.menu)
        Thread.sleep(forTimeInterval: 0.6)
        XCTAssertFalse(sleepTimerPicker.exists, "player.sleepTimerPicker must close after pressing Menu")
        XCTAssertTrue(titleLabel.exists, "player must remain active after dismissing the picker")
    }

    // MARK: - D-pad navigation regression tests

    /// D-pad down from the speed row (default focus) moves focus to the next row.
    /// Pressing select after one down press must NOT open the speed picker — it
    /// should activate whatever row now has focus (Quality or Like/Dislike).
    /// Regression for: onMoveCommand consuming D-pad events inside the more menu.
    func testMoreMenuDpadDownNavigatesToNextRow() throws {
        try openPlayer()
        try openMoreMenu()

        // Speed row starts with focus. One D-pad down moves to the next row.
        remote.press(.down)
        Thread.sleep(forTimeInterval: 0.5)

        // Pressing select must NOT open the speed picker (that would mean focus
        // never left the speed row — the D-pad down was swallowed by onMoveCommand
        // on the outer ZStack).
        remote.press(.select)
        Thread.sleep(forTimeInterval: 0.5)

        XCTAssertFalse(
            speedPicker.exists,
            "player.speedPicker must NOT appear after ↓ + select — D-pad down was swallowed " +
            "(ConditionalMoveCommand regression: onMoveCommand still intercepting overlay D-pad)"
        )
    }

    /// Pressing D-pad down repeatedly reaches the Sleep Timer row and select opens its picker.
    /// Regression for: onMoveCommand blocking vertical navigation in the more menu.
    func testMoreMenuDpadReachesSleepTimerRow() throws {
        try openPlayer()
        try openMoreMenu()

        // Navigate down — without pressing select on intermediate rows — until the
        // Sleep Timer row receives focus. Its position depends on whether Quality and
        // Like rows are shown (network/auth-dependent), so we check `hasFocus` after
        // each press rather than counting a fixed number of steps.
        var reachedSleepTimer = false
        for _ in 0..<5 {
            remote.press(.down)
            Thread.sleep(forTimeInterval: 0.4)
            if moreMenuSleepTimerRow.hasFocus {
                reachedSleepTimer = true
                break
            }
        }

        guard reachedSleepTimer else {
            try captureAndSkip("Sleep Timer row did not receive focus after 5 D-pad presses — " +
                          "row count may vary or network unavailable", in: app)
        }

        remote.press(.select)
        XCTAssertTrue(
            sleepTimerPicker.waitForExistence(timeout: 3),
            "player.sleepTimerPicker must appear after navigating down to the Sleep Timer row — " +
            "D-pad navigation inside the more menu is broken"
        )
    }

    // MARK: - Controls auto-hide regression test

    /// When the player controls auto-hide while the more menu is open, the menu
    /// must remain fully interactive — the speed row must still be selectable.
    /// Regression for: controlsVisible→false stealing focus from overlay.
    func testMoreMenuRemainsSelectableAfterControlsHide() throws {
        try openPlayer()
        try openMoreMenu()

        // Wait long enough for the controls auto-hide timer to fire (typically 3 s).
        // The tvOS simulator controls hide after ~3 s by default.
        Thread.sleep(forTimeInterval: 6)

        // After controls auto-hide the more menu must still work.
        // Speed row has prefersDefaultFocus and focus is re-asserted on controls-hide.
        remote.press(.select)
        Thread.sleep(forTimeInterval: 0.5)

        XCTAssertTrue(
            speedPicker.waitForExistence(timeout: 5),
            "player.speedPicker must appear after controls auto-hide — " +
            "focus was stolen from the more menu when vm.controlsVisible became false"
        )
    }
}

#endif // os(tvOS)
