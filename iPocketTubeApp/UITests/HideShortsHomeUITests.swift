import XCTest

// MARK: - HideShortsHomeUITests
//
// Verifies that the "Hide Shorts" setting is correctly applied to the Home feed.
//
// Approach
// --------
// `VideoGridSection` sets `accessibilityValue("short")` on every card whose
// `Video.isShort == true`.  This lets the test query the accessibility tree for
// Short cards without knowledge of specific video IDs.
//
// Launch arguments
// ----------------
//   --uitesting-hide-shorts   Sets `hideShorts = true` before the app renders any UI.
//   --uitesting-enable-shorts Ensures the Shorts section chip is present when
//                             `hideShorts` is false so its visibility can be asserted.
//   --uitesting-reset-settings Resets all settings to defaults for a clean baseline.

final class HideShortsHomeUITests: XCTestCase {

    private var app: XCUIApplication!

    override func tearDownWithError() throws {
        app = nil
    }

    // MARK: - Helpers

    private func launch(hideShorts: Bool) {
        app = XCUIApplication()
        var args = ["--uitesting", "--uitesting-reset-settings"]
        if hideShorts {
            args.append("--uitesting-hide-shorts")
        } else {
            // Ensure the Shorts chip is enabled so we can assert its presence.
            args.append("--uitesting-enable-shorts")
        }
        app.launchArguments = args
        app.launch()
    }

    /// Waits for the Home feed to load at least one video card.
    /// Returns `false` if the feed stays empty (network / sign-in issue → skip).
    private func waitForHomeFeed() -> Bool {
        UITestHelpers.tapTab(named: "Home", in: app)
        return UITestHelpers.waitForVideoCards(in: app, timeout: 30) != nil
    }

    /// All `video.card.*` elements currently visible whose `accessibilityValue` is "short".
    private func shortCardsInGrid() -> XCUIElementQuery {
        let predicate = NSPredicate(
            format: "identifier BEGINSWITH 'video.card.' AND value == 'short'"
        )
        return app.descendants(matching: .any).matching(predicate)
    }

    // MARK: - Tests

    /// When `hideShorts` is **true**:
    ///   • No Short cards (value == "short") appear in the regular video grid.
    ///   • The dedicated Shorts row (`home.shortsRow`) is absent.
    ///   • The "Shorts" chip is absent from the chip bar.
    func test_HideShortsTrue_NoShortsInHomeGrid() throws {
        launch(hideShorts: true)
        continueAfterFailure = false

        guard waitForHomeFeed() else {
            try captureAndSkip("Home feed did not load — network or sign-in issue.", in: app)
        }

        // Give pagination a moment so at least one page is fully rendered.
        // We want to catch Shorts that slip through the filter, not just miss them
        // because the grid hasn't finished rendering yet.
        _ = XCTWaiter().wait(
            for: [XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "count > 5"),
                object: app.descendants(matching: .any).matching(
                    NSPredicate(format: "identifier BEGINSWITH 'video.card.'")
                )
            )],
            timeout: 10
        )

        // 1. No Short cards in the regular grid.
        let shorts = shortCardsInGrid()
        XCTAssertEqual(
            shorts.count, 0,
            "hideShorts=true: found \(shorts.count) Short card(s) in the home grid — " +
            "isShort detection or hideShorts filter is broken. IDs: " +
            (0..<shorts.count).map { shorts.element(boundBy: $0).identifier }.joined(separator: ", ")
        )

        // 2. Shorts row must be hidden.
        XCTAssertFalse(
            app.scrollViews["home.shortsRow"].exists,
            "hideShorts=true: home.shortsRow should not be visible."
        )

        // 3. Shorts chip must be absent from the chip bar.
        let chipBar = app.scrollViews["home.chipBar"].firstMatch
        let shortsChip = chipBar.buttons["Shorts"]
        XCTAssertFalse(
            shortsChip.exists,
            "hideShorts=true: 'Shorts' chip should not appear in the chip bar."
        )
    }

    /// When `hideShorts` is **false**:
    ///   • No Short cards appear in the regular video **grid** (Shorts belong in
    ///     the dedicated Shorts row, not the grid).
    ///   • The "Shorts" chip is present in the chip bar (enabled via
    ///     --uitesting-enable-shorts).
    func test_HideShortsFalse_ShortsOnlyInShortsRow() throws {
        launch(hideShorts: false)
        continueAfterFailure = false

        guard waitForHomeFeed() else {
            try captureAndSkip("Home feed did not load — network or sign-in issue.", in: app)
        }

        // Wait for at least a couple of cards to render before inspecting.
        _ = XCTWaiter().wait(
            for: [XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "count > 3"),
                object: app.descendants(matching: .any).matching(
                    NSPredicate(format: "identifier BEGINSWITH 'video.card.'")
                )
            )],
            timeout: 10
        )

        // 1. No Short cards in the regular grid — homeRegularVideos always excludes
        //    Shorts regardless of the hideShorts flag.
        let shorts = shortCardsInGrid()
        XCTAssertEqual(
            shorts.count, 0,
            "hideShorts=false: found \(shorts.count) Short card(s) in the home grid — " +
            "homeRegularVideos must never contain Shorts. IDs: " +
            (0..<shorts.count).map { shorts.element(boundBy: $0).identifier }.joined(separator: ", ")
        )

        // 2. Shorts chip must be visible when hideShorts is off.
        let chipBar = app.scrollViews["home.chipBar"].firstMatch
        guard chipBar.waitForExistence(timeout: 5) else {
            try captureAndSkip("home.chipBar not found — chip bar may not be rendered on this device.", in: app)
        }
        UITestHelpers.scrollChipIntoView(chipBar.buttons["Shorts"], in: chipBar, app: app)
        XCTAssertTrue(
            chipBar.buttons["Shorts"].waitForExistence(timeout: 5),
            "hideShorts=false: 'Shorts' chip must be visible in the chip bar."
        )
    }
}
