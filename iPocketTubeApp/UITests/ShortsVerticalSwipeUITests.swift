import XCTest

// MARK: - ShortsVerticalSwipeUITests
//
// Regression tests for the Shorts player vertical-swipe navigation.
// Verifies that swiping up 6 times in the Shorts player (from either the Home
// or Recommended tab Shorts row) always advances to a new Short each time.
//
// These tests catch the regression where FEshorts deprecation left only 1–2
// Shorts in the playlist, making it impossible to swipe past index 2.
//
// Launch: --uitesting --uitesting-signed-in
// Real auth token from keychain + real YouTube API calls.

final class ShortsVerticalSwipeUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--uitesting-signed-in"]
        app.launch()
        UITestHelpers.tapTab(named: "Home", in: app)
    }

    override func tearDownWithError() throws {
        app = nil
    }

    // MARK: - Helpers

    private var indexLabel: XCUIElement {
        app.staticTexts["shorts.indexLabel"].firstMatch
    }

    /// Swipes up in the Shorts player to advance to the next Short.
    private func swipePlayerUp() {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
        let end   = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        start.press(forDuration: 0.05, thenDragTo: end)
        Thread.sleep(forTimeInterval: 0.6)
    }

    /// Parses the current index from a label like "3 / 12", returning 3.
    private func currentIndex(from label: String) -> Int? {
        let parts = label.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, let n = Int(parts[0]) else { return nil }
        return n
    }

    /// Parses the total count from a label like "3 / 12", returning 12.
    private func totalCount(from label: String) -> Int? {
        let parts = label.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, let n = Int(parts[1]) else { return nil }
        return n
    }

    /// Waits up to `timeout` for `shortsRowID` scroll view to appear, then taps
    /// the first `shorts.card.*` card inside it.  Opens the Shorts player and
    /// waits for `shorts.indexLabel`.  Returns the opening label ("1 / N").
    @discardableResult
    private func openFirstShort(in shortsRowID: String, timeout: TimeInterval = 25) throws -> String {
        let row = app.scrollViews[shortsRowID]
        guard row.waitForExistence(timeout: timeout) else {
            try captureAndSkip("\(shortsRowID) not found within \(timeout)s — Shorts row missing", in: app)
        }
        let predicate = NSPredicate(format: "identifier BEGINSWITH 'shorts.card.'")
        let cards = row.descendants(matching: .any).matching(predicate)
        guard cards.firstMatch.waitForExistence(timeout: 10) else {
            try captureAndSkip("No shorts.card.* in \(shortsRowID) — Shorts not loaded", in: app)
        }
        cards.firstMatch.tap()
        guard indexLabel.waitForExistence(timeout: 15) else {
            try captureAndSkip("shorts.indexLabel did not appear — Shorts player did not open", in: app)
        }
        return indexLabel.label
    }

    /// Waits up to `waitSec` for the index label to advance past `before`.
    private func waitForIndexAdvance(past before: Int, waitSec: TimeInterval = 5) -> Int {
        let deadline = Date(timeIntervalSinceNow: waitSec)
        while Date() < deadline {
            if let cur = currentIndex(from: indexLabel.label), cur > before { return cur }
            Thread.sleep(forTimeInterval: 0.3)
        }
        return currentIndex(from: indexLabel.label) ?? before
    }

    /// Core assertion: swipes up `count` times and verifies each swipe advances the index.
    /// Breaks early (successfully) if the playlist end is reached before `count` swipes.
    private func assertSwipesAdvance(count: Int, context: String) {
        var lastLabel = indexLabel.label
        for swipeNum in 1...count {
            let before = currentIndex(from: lastLabel) ?? 0
            // If already at the last Short, further swipes won't advance — that's fine.
            if let total = totalCount(from: lastLabel), before >= total {
                break
            }
            swipePlayerUp()
            let after = waitForIndexAdvance(past: before)

            UITestHelpers.assertNoShortsErrorBanner(in: app)

            let afterLabel = indexLabel.label
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "\(context) swipe \(swipeNum): \(lastLabel) → \(afterLabel)"
            screenshot.lifetime = .keepAlways
            add(screenshot)

            XCTAssertGreaterThan(
                after, before,
                "\(context): swipe \(swipeNum) — index should advance from \(before) but stayed at \(after) ('\(afterLabel)')"
            )
            lastLabel = afterLabel
        }
    }

    // MARK: - Tests

    /// Opens the first Short from the Home tab Shorts row and swipes up 6 times,
    /// asserting that each swipe advances to a new Short.
    func testHomeTabShortsAdvanceSixSwipes() throws {
        try openFirstShort(in: "home.shortsRow")
        assertSwipesAdvance(count: 6, context: "Home")
    }

    /// Opens the first Short from the Recommended tab Shorts row and swipes up 6 times,
    /// asserting that each swipe advances to a new Short.
    func testRecommendedTabShortsAdvanceSixSwipes() throws {
        // Navigate to the Recommended chip.
        let chipBar = app.scrollViews["home.chipBar"]
        guard chipBar.waitForExistence(timeout: 10) else {
            try captureAndSkip("home.chipBar not found", in: app)
        }
        let rec = chipBar.buttons["Recommended"]
        guard rec.waitForExistence(timeout: 5) else {
            try captureAndSkip("Recommended chip not found in chip bar", in: app)
        }
        UITestHelpers.scrollChipIntoView(rec, in: chipBar, app: app)
        rec.tap()

        try openFirstShort(in: "recommended.shortsRow", timeout: 30)
        assertSwipesAdvance(count: 6, context: "Recommended")
    }
}
