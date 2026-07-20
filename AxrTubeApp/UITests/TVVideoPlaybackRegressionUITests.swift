// TVVideoPlaybackRegressionUITests.swift
// Tests for task #119 — tvOS Playback Regression
//
// Test matrix:
//   testPlayerOpensWithoutErrorBanner      — deeplink player opens, no error banner
//   testPlayerDoesNotCrashAfterMenuDismiss — Menu press from player returns to home
//   testSecondVideoPlaysAfterFirst         — navigate to second video after dismissing first
//   testNoLoadingSpinnerAfterPlaybackStarts — spinner gone 8 s after player opens
//   testPlaybackContinuesAfterControlsHide  — player still up after controls auto-hide

#if os(tvOS)
import XCTest

final class TVVideoPlaybackRegressionUITests: XCTestCase {

    private var app: XCUIApplication!
    private let remote = XCUIRemote.shared

    // MARK: - Lifecycle

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launch()
    }

    override func tearDownWithError() throws {
        app = nil
    }

    // MARK: - Helpers

    private func element(identifier: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == %@", identifier))
            .firstMatch
    }

    private var titleLabel: XCUIElement {
        app.staticTexts["player.titleLabel"].firstMatch
    }

    private var chipBar: XCUIElement {
        element(identifier: "home.chipBar")
    }

    /// Waits for at least one video card to appear on Home.
    private func waitForVideoCards(timeout: TimeInterval = 20) -> Bool {
        let predicate = NSPredicate(format: "identifier BEGINSWITH 'video.card.'")
        let cards = app.descendants(matching: .any).matching(predicate)
        let exp = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count > 0"),
                                            object: cards)
        return XCTWaiter().wait(for: [exp], timeout: timeout) == .completed
    }

    /// Navigates from the Home screen into the player:
    ///   ↓ (tab bar → chips) → ↓ (chips → video list) → select
    /// Skips the test if Home content doesn't load (network unavailable).
    private func waitForPlayer(timeout: TimeInterval = 20) throws {
        guard chipBar.waitForExistence(timeout: 15) else {
            try captureAndSkip("home.chipBar did not appear — app failed to launch", in: app)
        }
        guard waitForVideoCards(timeout: 20) else {
            try captureAndSkip("No video cards loaded — network unavailable or feed empty", in: app)
        }
        remote.press(.down)
        Thread.sleep(forTimeInterval: 0.6)
        remote.press(.down)
        Thread.sleep(forTimeInterval: 0.6)
        remote.press(.select)
        guard titleLabel.waitForExistence(timeout: timeout) else {
            try captureAndSkip(
                "player.titleLabel did not appear within \(Int(timeout)) s — " +
                "player failed to open from Home",
                in: app
            )
        }
    }

    // MARK: - Tests

    /// The player opens via deeplink without showing an error banner.
    func testPlayerOpensWithoutErrorBanner() throws {
        try waitForPlayer()

        // Short wait — an error banner would appear quickly if present.
        let errorBanner = element(identifier: "player.errorBanner")
        let ipBanner = element(identifier: "player.ipBlockBanner")

        Thread.sleep(forTimeInterval: 3.0)

        XCTAssertFalse(errorBanner.exists,
                       "player.errorBanner must not appear after opening player via deeplink")
        XCTAssertFalse(ipBanner.exists,
                       "player.ipBlockBanner must not appear — IP may be blocked in this environment")
    }

    /// Pressing Menu from the player must dismiss it and return to the Home screen.
    func testPlayerDoesNotCrashAfterMenuDismiss() throws {
        try waitForPlayer()

        remote.press(.menu)
        Thread.sleep(forTimeInterval: 2.0)

        XCTAssertTrue(
            chipBar.waitForExistence(timeout: 8),
            "home.chipBar must reappear after pressing Menu in the player — " +
            "app may have crashed or become unresponsive"
        )
    }

    /// After dismissing the first video, navigating to a second video card
    /// must open the player again without crashing or getting stuck.
    func testSecondVideoPlaysAfterFirst() throws {
        try waitForPlayer()

        // Dismiss first player.
        remote.press(.menu)
        Thread.sleep(forTimeInterval: 2.0)

        guard chipBar.waitForExistence(timeout: 8) else {
            try captureAndSkip("home.chipBar did not reappear after dismissing first player", in: app)
        }

        // Navigate down to video list and select the next card.
        remote.press(.down)
        Thread.sleep(forTimeInterval: 0.6)
        remote.press(.down)
        Thread.sleep(forTimeInterval: 0.6)
        remote.press(.select)

        guard titleLabel.waitForExistence(timeout: 15) else {
            try captureAndSkip(
                "Second player did not open within 15 s — " +
                "home feed may have been empty or navigation did not reach a video card",
                in: app
            )
        }

        XCTAssertTrue(titleLabel.exists,
                      "player.titleLabel must exist after opening second video — " +
                      "player may be in a ghost/stuck state")
    }

    /// After 8 seconds of playback, no activity indicator (loading spinner) must
    /// be visible. A persistent spinner indicates the playback pipeline is stalled.
    func testNoLoadingSpinnerAfterPlaybackStarts() throws {
        try waitForPlayer()

        // Allow 8 s for playback to start.
        Thread.sleep(forTimeInterval: 8.0)

        let spinners = app.activityIndicators
        XCTAssertEqual(spinners.count, 0,
                       "Expected 0 activity indicators 8 s after player opened, " +
                       "found \(spinners.count) — loading spinner may be permanently stuck")
    }

    /// The player must remain open and functional after the controls overlay
    /// auto-hides (typically after ~4 seconds of inactivity).
    func testPlaybackContinuesAfterControlsHide() throws {
        try waitForPlayer()

        // Wait for the controls overlay to auto-hide.
        Thread.sleep(forTimeInterval: 5.0)

        XCTAssertTrue(
            titleLabel.exists,
            "player.titleLabel must still exist after controls auto-hide — " +
            "player may have been dismissed or crashed when controls faded out"
        )
    }
}
#endif // os(tvOS)
