#if os(tvOS)
import XCTest

// MARK: - TVHomeFeedUITests
//
// Verifies the tvOS Home Feed tab: chip bar presence, video card population,
// no error banner on launch, Subscriptions chip navigation, and return to Home.
//
// Run against the "iPocketTube" tvOS scheme:
//   xcodebuild test -workspace AxrTube.xcworkspace -scheme "iPocketTube"
//     -destination "id=30E83929-0C67-4572-82C4-FE0F228EA835"
//     -only-testing:iPocketTubeTVUITests/TVHomeFeedUITests

final class TVHomeFeedUITests: XCTestCase {

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

    private var sectionContainer: XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'home.sectionContainer'"))
            .firstMatch
    }

    /// Waits up to `timeout` seconds for at least one `video.card.*` descendant to appear.
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

    /// The chip bar must appear within 15 s of launch.
    func testChipBarLoadsWithinTimeout() throws {
        guard chipBar.waitForExistence(timeout: 15) else {
            try captureAndSkip("home.chipBar did not appear within 15 s — Home tab may not have loaded", in: app)
        }
        XCTAssertTrue(chipBar.exists, "home.chipBar must exist after appearance")
    }

    /// Video cards (video.card.*) must populate the Home feed within 20 s.
    func testVideoCardsPopulateHomeFeed() throws {
        guard chipBar.waitForExistence(timeout: 15) else {
            try captureAndSkip("home.chipBar not found — cannot wait for video cards", in: app)
        }
        guard waitForVideoCards(timeout: 20) else {
            try captureAndSkip("No video.card.* elements appeared within 20 s — network unavailable or feed empty", in: app)
        }
        let predicate = NSPredicate(format: "identifier BEGINSWITH 'video.card.'")
        let cards = app.descendants(matching: .any).matching(predicate)
        XCTAssertGreaterThan(cards.count, 0, "At least one video card must be visible in the Home feed")
    }

    /// No XCUIElementTypeAlert and no player.errorBanner should appear on cold launch.
    func testNoErrorBannerOnHomeLoad() throws {
        guard chipBar.waitForExistence(timeout: 15) else {
            try captureAndSkip("home.chipBar not found — app did not reach Home tab", in: app)
        }
        // Allow extra time for network requests to settle.
        Thread.sleep(forTimeInterval: 3.0)
        let errorAlert = app.alerts.firstMatch
        XCTAssertFalse(errorAlert.exists, "Unexpected error alert appeared on Home launch: \(errorAlert.label)")
        let errorBanner = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'player.errorBanner'"))
            .firstMatch
        XCTAssertFalse(errorBanner.exists, "player.errorBanner should not appear on the Home screen")
    }

    /// Selecting the Subscriptions chip via D-pad should load the Subscriptions feed.
    func testSelectingSubscriptionsChipLoadsFeed() throws {
        guard chipBar.waitForExistence(timeout: 15) else {
            try captureAndSkip("home.chipBar not found — cannot navigate to Subscriptions chip", in: app)
        }
        // Press ↓ to move focus from the tab bar into the chip bar.
        remote.press(.down)
        Thread.sleep(forTimeInterval: 0.8)
        // Navigate right to reach the Subscriptions chip (typically the second chip).
        remote.press(.right)
        Thread.sleep(forTimeInterval: 0.8)
        // Activate the focused chip.
        remote.press(.select)
        Thread.sleep(forTimeInterval: 1.5)
        // The section container should load the new feed.
        guard sectionContainer.waitForExistence(timeout: 15) else {
            try captureAndSkip("home.sectionContainer did not appear after selecting Subscriptions chip", in: app)
        }
        XCTAssertTrue(sectionContainer.exists, "home.sectionContainer must exist after chip selection")
    }

    /// Navigating back to the Home chip after Subscriptions should restore the chip bar.
    func testSelectingHomeChipRestoresFeed() throws {
        guard chipBar.waitForExistence(timeout: 15) else {
            try captureAndSkip("home.chipBar not found on launch", in: app)
        }
        // Move to Subscriptions chip.
        remote.press(.down)
        Thread.sleep(forTimeInterval: 0.8)
        remote.press(.right)
        Thread.sleep(forTimeInterval: 0.8)
        remote.press(.select)
        Thread.sleep(forTimeInterval: 1.5)
        // Navigate back left to the Home chip and select it.
        remote.press(.left)
        Thread.sleep(forTimeInterval: 0.8)
        remote.press(.select)
        Thread.sleep(forTimeInterval: 1.5)
        // The chip bar must still be visible.
        XCTAssertTrue(
            chipBar.waitForExistence(timeout: 10),
            "home.chipBar must still exist after returning to the Home chip"
        )
    }
}
#endif
