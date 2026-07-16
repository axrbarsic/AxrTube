import XCTest

// MARK: - SubscriptionsPlaybackUITests
//
// End-to-end UI test that:
//   1. Opens the Subscriptions chip from the Home chip bar.
//   2. Waits for the feed to populate.
//   3. Taps the first video card to open PlayerView.
//   4. Waits for the player to load and stream to start.
//   5. Asserts no error banner or alert is shown.
//
// Error signals monitored:
//   • `player.errorBanner` — PlayerView overlay shown when PlaybackViewModel.error is set
//     (stream fetch failure, unsupported format, etc.)
//   • app.alerts["Error"]  — BrowseView alert raised for non-auth HTTP errors from the feed
//
// Requirements:
//   • The simulator must have network access.
//   • Run on an iOS 17+ simulator with the iPocketTubeApp scheme selected.
//   • A signed-in account is expected so the Subscriptions feed is non-empty.

final class SubscriptionsPlaybackUITests: XCTestCase {

    private var app: XCUIApplication!

    // MARK: - Lifecycle

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["--uitesting", "--uitesting-disable-tos-player-on-ios"]
        app.launch()
    }

    override func tearDownWithError() throws {
        app = nil
    }

    // MARK: - Tests

    /// Opens Subscriptions, taps the first video, waits for playback to begin,
    /// and asserts that neither a player error banner nor a feed error alert appears.
    func testSubscriptionsFirstVideoPlaysWithoutErrors() throws {
        // 1. Make sure the Home tab is active so the chip bar is visible.
        tapTab(named: "Home")

        let chipBar = app.scrollViews["home.chipBar"]
        XCTAssertTrue(chipBar.waitForExistence(timeout: 10), "Chip bar must appear on the Home tab")

        // 2. Scroll the chip bar until the Subscriptions chip is fully on screen, then tap it.
        let chip = chipBar.buttons["Subscriptions"]
        guard chip.waitForExistence(timeout: 5) else {
            try captureAndSkip("Subscriptions chip not found — section may be disabled in settings", in: app)
        }
        scrollChipIntoView(chip, in: chipBar)
        chip.tap()

        // 3. Wait for the Subscriptions feed to populate (at least one video card).
        let predicate = NSPredicate(format: "identifier BEGINSWITH 'video.card.'")
        let cards = app.descendants(matching: .any).matching(predicate)
        let feedLoaded = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count > 0"),
                                                   object: cards)
        guard XCTWaiter().wait(for: [feedLoaded], timeout: 20) == .completed else {
            try captureAndSkip("Subscriptions feed did not load within 20 s — network unavailable or feed empty", in: app)
        }

        // Assert no alert appeared while loading the feed.
        XCTAssertFalse(app.alerts["Error"].exists,
                       "A feed 'Error' alert appeared while loading the Subscriptions section")

        // 4. Tap the first video card.
        let firstCard = cards.firstMatch
        firstCard.tap()

        // 5. Wait for PlayerView to open — the always-visible title label is the signal.
        let titleLabel = app.staticTexts["player.titleLabel"].firstMatch
        XCTAssertTrue(titleLabel.waitForExistence(timeout: 15),
                      "player.titleLabel must appear after tapping a video — PlayerView did not open")

        let videoTitle = titleLabel.label

        // 6. Give the stream 10 s to buffer and begin playing.
        Thread.sleep(forTimeInterval: 10)

        // 7. Assert no player error banner appeared.
        let errorBanner = app.otherElements["player.errorBanner"].firstMatch
        XCTAssertFalse(
            errorBanner.exists,
            "player.errorBanner appeared during playback of '\(videoTitle)' — " +
            "PlaybackViewModel.error was set (stream fetch or format error)"
        )

        // 8. Assert no feed-level error alert appeared (belt-and-suspenders).
        XCTAssertFalse(app.alerts["Error"].exists,
                       "An 'Error' alert appeared during or after opening '\(videoTitle)'")

        // 9. Confirm the player is still open — title label still visible.
        XCTAssertTrue(titleLabel.exists,
                      "player.titleLabel disappeared — PlayerView may have been dismissed unexpectedly")
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

    /// Scrolls `chip` into the fully-visible area of `chipBar` before tapping.
    /// Uses `chip.frame` (safe for off-screen elements, no hittability assertion)
    /// to decide scroll direction.
    private func scrollChipIntoView(_ chip: XCUIElement, in chipBar: XCUIElement) {
        let screenWidth = app.windows.firstMatch.frame.width
        let near = chipBar.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5))
        let far  = chipBar.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5))

        for _ in 0..<8 {
            let frame = chip.frame
            if frame.origin.x >= 4 && frame.maxX <= screenWidth - 4 { break }
            if frame.origin.x < 4 {
                near.press(forDuration: 0.05, thenDragTo: far)
            } else {
                far.press(forDuration: 0.05, thenDragTo: near)
            }
        }
    }
}
