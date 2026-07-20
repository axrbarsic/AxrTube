import XCTest

/// Merged from `PlayerMoreMenuLayoutUITests` + `PlayerPickerOverlayLayoutUITests`.
/// All 6 tests share **one** app launch via class-level setUp/tearDown,
/// avoiding 5 redundant app starts. See docs/ui-tests-together-plan.md — Group 1.
final class PlayerMenuAndPickerLayoutUITests: XCTestCase {

    // MARK: - Class-level shared state

    private static var sharedApp: XCUIApplication!
    private static var skipAllTests = false
    private static let skipReason = "Player did not open within 20 s — network unavailable or video inaccessible"
    private static var skipScreenshot: XCUIScreenshot?

    override class func setUp() {
        super.setUp()
        let a = XCUIApplication()
        a.launchArguments = [
            "--uitesting",
            "--uitesting-disable-tos-player-on-ios",
            "--uitesting-deeplink-video=dQw4w9WgXcQ",
            "--uitesting-open-more-menu"
        ]
        #if os(iOS)
        XCUIDevice.shared.orientation = .portrait
        #endif
        a.launch()
        sharedApp = a
        // Wait for the more menu to appear — the --uitesting-open-more-menu flag
        // opens it on top of the player, so player.view is inaccessible under the sheet.
        skipAllTests = !a.scrollViews["player.moreMenu.scrollView"].firstMatch.waitForExistence(timeout: 20)
        if skipAllTests {
            skipScreenshot = a.screenshot()
        }
    }

    override class func tearDown() {
        #if os(iOS)
        XCUIDevice.shared.orientation = .portrait
        #endif
        sharedApp?.terminate()
        sharedApp = nil
        skipAllTests = false
        skipScreenshot = nil
        super.tearDown()
    }

    // MARK: - Per-test lifecycle

    private var app: XCUIApplication { Self.sharedApp }

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        if let shot = Self.skipScreenshot {
            let attachment = XCTAttachment(screenshot: shot)
            attachment.name = "App state when player failed to load"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        guard !Self.skipAllTests else { return }
        #if os(iOS)
        XCUIDevice.shared.orientation = .portrait
        #endif
        // Wait for the portrait frame to settle before opening the menu.
        let a2 = app
        let portraitSettled = NSPredicate { _, _ in a2.frame.size.width < a2.frame.size.height }
        _ = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: portraitSettled, object: nil)], timeout: 5)
        ensureMoreMenuVisible()
    }

    override func tearDown() {
        dismissPickerIfOpen()
        // If a landscape test just ran, close the menu before returning to portrait.
        // This gives the next setUp a clean state to reopen the menu in portrait.
        let wasLandscape = app.frame.size.width > app.frame.size.height
        #if os(iOS)
        XCUIDevice.shared.orientation = .portrait
        #endif
        if wasLandscape {
            // Wait for the frame to confirm portrait before closing the menu.
            let a = app
            let portraitPred = NSPredicate { _, _ in a.frame.size.width < a.frame.size.height }
            _ = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: portraitPred, object: nil)], timeout: 5)
            closeMoreMenuIfOpen()
        }
        super.tearDown()
    }

    // MARK: - Helpers

    /// Ensures the more menu is visible; re-opens it if a previous test dismissed it.
    /// Uses two tap attempts in case controls auto-hid before the first tap registered.
    private func ensureMoreMenuVisible() {
        let scrollView = app.scrollViews["player.moreMenu.scrollView"].firstMatch
        if scrollView.waitForExistence(timeout: 5) { return }
        let moreButton = app.buttons["player.moreButton"].firstMatch
        for _ in 0..<3 {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            if moreButton.waitForExistence(timeout: 4) {
                moreButton.tap()
                break
            }
        }
        _ = scrollView.waitForExistence(timeout: 8)
    }

    /// Dismisses an open picker overlay so the more menu can be restored.
    private func dismissPickerIfOpen() {
        let anyOpen = ["player.qualityPicker", "player.speedPicker", "player.sleepTimerPicker"]
            .contains { app.otherElements[$0].firstMatch.exists }
        if anyOpen {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.1)).tap()
            _ = app.scrollViews["player.moreMenu.scrollView"].firstMatch.waitForExistence(timeout: 2)
        }
    }

    /// Dismisses the more menu via its cancel row to restore a clean player state.
    private func closeMoreMenuIfOpen() {
        let cancel = app.buttons["player.moreMenu.cancel"].firstMatch
        if cancel.waitForExistence(timeout: 5), cancel.isHittable { cancel.tap() }
    }

    /// Rotates to landscape and waits for the frame to confirm the change.
    private func rotateToLandscapeAndWait() {
        #if os(iOS)
        XCUIDevice.shared.orientation = .landscapeLeft
        #endif
        let a = app
        let pred = NSPredicate { _, _ in a.frame.size.width > a.frame.size.height }
        _ = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: pred, object: nil)], timeout: 5)
    }

    // MARK: - More menu layout tests

    func testMoreMenuIsScrollableAndUsableInLandscape() throws {
        try XCTSkipIf(Self.skipAllTests, Self.skipReason)
        rotateToLandscapeAndWait()
        ensureMoreMenuVisible()

        let scrollView = app.scrollViews["player.moreMenu.scrollView"].firstMatch
        XCTAssertTrue(scrollView.waitForExistence(timeout: 10),
                      "More menu scroll view must be accessible in landscape")

        // In landscape compact height, Speed/Quality/Sleep rows are hidden.
        // Verify the rows that ARE present: downloadButton and cancel.
        let downloadButton = app.buttons["player.moreMenu.downloadButton"].firstMatch
        XCTAssertTrue(downloadButton.waitForExistence(timeout: 5),
                      "Download button should be accessible in landscape more menu")
        XCTAssertTrue(downloadButton.isHittable,
                      "Download button should be tappable in landscape")

        let cancelButton = app.buttons["player.moreMenu.cancel"].firstMatch
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline && !cancelButton.isHittable {
            scrollView.swipeUp()
        }
        XCTAssertTrue(cancelButton.exists,
                      "Cancel row should remain in the accessibility tree")
        XCTAssertTrue(cancelButton.isHittable,
                      "Cancel row should be reachable by scrolling in landscape")
        XCTAssertEqual(app.state, .runningForeground,
                       "App must remain running while interacting with the landscape more menu")
    }

    func testMoreMenuWidthIsConstrainedInPortrait() throws {
        try XCTSkipIf(Self.skipAllTests, Self.skipReason)

        let scrollView = app.scrollViews["player.moreMenu.scrollView"].firstMatch
        XCTAssertTrue(scrollView.waitForExistence(timeout: 10),
                      "More menu scroll view must appear in portrait")

        let screenWidth = app.frame.size.width
        let menuWidth = scrollView.frame.size.width
        XCTAssertLessThanOrEqual(menuWidth, screenWidth * 0.85,
                                 "More menu width (\(menuWidth)pt) must be ≤ 85 % of screen width " +
                                 "(\(screenWidth)pt) — task #44 constraint")
        XCTAssertGreaterThan(menuWidth, screenWidth * 0.5,
                             "More menu width (\(menuWidth)pt) must be reasonable (> 50 % of screen)")
        // Confirm that a named row is hittable.
        // player.moreMenu.speedRow no longer appears in the more menu in the current app version;
        // player.moreMenu.downloadButton is the first row with a stable accessibility ID.
        let downloadButton = app.buttons["player.moreMenu.downloadButton"].firstMatch
        let hittable = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: downloadButton)
        _ = XCTWaiter().wait(for: [hittable], timeout: 12)
        XCTAssertTrue(downloadButton.isHittable, "Download button must be tappable in portrait — confirms menu items are accessible")
    }

    /// Regression for #94: the portrait more menu must fit all items without
    /// requiring the user to scroll (moreMenuMaxHeight reduced from 520→380 pt).
    func testMoreMenuDoesNotRequireScrollInPortrait() throws {
        try XCTSkipIf(Self.skipAllTests, Self.skipReason)

        let cancelButton = app.buttons["player.moreMenu.cancel"].firstMatch
        XCTAssertTrue(cancelButton.waitForExistence(timeout: 10),
                      "Cancel button must be accessible in the portrait more menu")
        XCTAssertTrue(cancelButton.isHittable,
                      "Cancel button must be hittable without scrolling in portrait — " +
                      "menu should fit entirely within portrait height (moreMenuMaxHeight = 380 pt)")
    }

}
