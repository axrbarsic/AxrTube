import XCTest

// MARK: - CategoryChipHTTP400UITests
//
// End-to-end UI tests that open every category chip in the Home chip bar and
// assert that no HTTP error alert is presented by the BrowseView for any of
// them.  BrowseViewModel surfaces non-auth network errors (including HTTP 400)
// by setting vm.error, which BrowseView materialises as an alert titled "Error".
// Asserting the alert does NOT appear is therefore equivalent to asserting that
// no HTTP 4xx/5xx error was returned for that chip's feed request.
//
// Requirements:
//   • The simulator must have network access so InnerTube requests are made.
//   • Run on an iOS 17+ simulator with the iPocketTubeApp scheme selected.

final class CategoryChipHTTP400UITests: XCTestCase {

    private var app: XCUIApplication!

    // All known chip labels in display order, derived from BrowseSection.allSections.
    // "Home" is always first; the test skips it (already loaded on launch).
    private static let allChipNames: [String] = [
        "Home",
        "Recommended",
        "Subscriptions",
        "History",
        "Playlists",
        "Channels",
        "Shorts",
        "Music",
        "Gaming",
        "News",
        "Live",
        "Sports",
    ]

    // MARK: - Lifecycle

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["--uitesting"]
        app.launch()
    }

    override func tearDownWithError() throws {
        app = nil
    }

    // MARK: - Helpers

    /// Taps the named tab, supporting both the bottom tab bar (iPhone) and the
    /// iPadOS 18 sidebar where tab items appear as standalone buttons.
    private func tapTab(named label: String, timeout: TimeInterval = 5) {
        let tabBarButton = app.tabBars.buttons[label]
        if tabBarButton.waitForExistence(timeout: min(timeout, 3)) {
            tabBarButton.tap()
            return
        }
        // iPad iOS 18 sidebar: tab items render as buttons outside the tab bar.
        let sidebarButton = app.buttons[label].firstMatch
        XCTAssertTrue(sidebarButton.waitForExistence(timeout: timeout),
                      "'\(label)' navigation item not found in tab bar or sidebar")
        sidebarButton.tap()
    }

    // MARK: - Tests

    /// Taps each visible category chip and asserts that the "Error" alert
    /// presented by BrowseView on any HTTP error does NOT appear.
    func testNoCategoryChipTriggersHTTP400() {
        tapTab(named: "Home")

        let chipBar = app.scrollViews["home.chipBar"]
        XCTAssertTrue(chipBar.waitForExistence(timeout: 10), "Chip bar must appear on Home tab")

        var testedChips: [String] = []

        for (index, chipName) in Self.allChipNames.dropFirst().enumerated() {
            guard tapChip(named: chipName, in: chipBar, chipIndex: index) else {
                // Chip not enabled in current settings — skip silently.
                continue
            }

            // Wait up to 15 s for feed to settle (video cards, empty state, or error alert).
            waitForFeedToSettle()

            // BrowseViewModel sets vm.error for any non-auth network failure
            // (HTTP 400 included); BrowseView renders that as an alert titled "Error".
            let errorAlert = app.alerts["Error"]
            XCTAssertFalse(
                errorAlert.exists,
                "An 'Error' alert appeared after tapping the '\(chipName)' chip — " +
                "this indicates an HTTP error was returned for that category's feed request."
            )
            // Dismiss if present so remaining chips can still run.
            if errorAlert.exists {
                errorAlert.buttons.firstMatch.tap()
            }

            testedChips.append(chipName)
        }

        XCTAssertFalse(testedChips.isEmpty, "At least one chip besides 'Home' must have been tested")
    }

    // MARK: - Chip interaction helpers

    /// Scrolls the chip bar until `name` is fully on screen, then taps it.
    /// Uses `chip.frame` (does not throw for off-screen elements) to decide
    /// which direction to scroll, avoiding the hittability check that throws
    /// for partially clipped elements.
    /// Returns `false` if the chip button doesn't exist in the current settings.
    @discardableResult
    private func tapChip(named name: String, in chipBar: XCUIElement, chipIndex: Int) -> Bool {
        let chip = chipBar.buttons[name]
        guard chip.waitForExistence(timeout: 3) else { return false }

        let screenWidth = app.windows.firstMatch.frame.width
        // Use app-level coordinates at the chip bar's y-position so the drag
        // gesture reliably scrolls the ScrollView rather than landing on a chip
        // button and inadvertently triggering a section change.
        let rightEdge = app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.09))
        let leftEdge  = app.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.09))

        // Scroll until the chip is fully inside the visible screen bounds.
        for _ in 0..<8 {
            let frame = chip.frame
            if frame.origin.x >= 4 && frame.maxX <= screenWidth - 4 { break }
            if frame.origin.x < 4 {
                // Chip is off-screen to the left — drag left→right to scroll backward.
                leftEdge.press(forDuration: 0.05, thenDragTo: rightEdge)
            } else {
                // Chip is off-screen to the right — drag right→left to scroll forward.
                rightEdge.press(forDuration: 0.05, thenDragTo: leftEdge)
            }
            // Allow the scroll animation and accessibility tree to settle.
            Thread.sleep(forTimeInterval: 0.3)
        }

        guard chip.exists else { return false }
        chip.tap()
        return true
    }

    /// Waits a fixed 5 s interval for the InnerTube request triggered by the
    /// chip tap to complete and for the view to settle before asserting.
    private func waitForFeedToSettle() {
        Thread.sleep(forTimeInterval: 5)
    }
}

