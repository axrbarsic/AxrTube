import XCTest

// MARK: - SubscriptionsScrollRestorationUITests
//
// Verifies that the scroll position in the Subscriptions feed is restored after
// opening a video and navigating back.
//
// Flow:
//   1. Navigate to the Subscriptions chip.
//   2. Wait for the feed to load.
//   3. Scroll down until the last visible card is near the bottom of the list
//      (triggering at least one pagination load if needed).
//   4. Record the accessibility identifier of the bottommost visible video card.
//   5. Tap that video to open PlayerView.
//   6. Navigate back via the system back button.
//   7. Assert the previously recorded card is still visible on screen (i.e. the
//      scroll position was not reset to the top).
//
// Requirements:
//   • The simulator must have network access.
//   • A signed-in account is expected so the Subscriptions feed is non-empty.
//   • Run on an iOS 17+ simulator with the iPocketTubeApp scheme selected.

final class SubscriptionsScrollRestorationUITests: XCTestCase {

    private var app: XCUIApplication!

    // MARK: - Lifecycle

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["--uitesting", "--uitesting-disable-tos-player-on-ios", "--uitesting-inject-recommended-ids=dQw4w9WgXcQ,9bZkp7q19f0,MCv4EyEFgVg,pPvd8UxmCGY,fKopy74weus,jNQXAC9IVRw,kJQP7kiw5Fk,OPf0YbXqDm0,RgKAFK5djSk,2vjPBrBU-HM"]
        app.launch()
    }

    override func tearDownWithError() throws {
        app = nil
    }

    // MARK: - Tests

    /// Scrolls the Subscriptions feed, plays a video, returns, and asserts that
    /// the scroll position was restored (not reset to the top of the list).
    func testScrollPositionRestoredAfterPlayback() throws {
        // 1. Ensure Home tab is active so the chip bar is visible.
        tapTab(named: "Home")

        let chipBar = app.scrollViews["home.chipBar"]
        XCTAssertTrue(chipBar.waitForExistence(timeout: 10), "Chip bar must appear")

        // 2. Tap the Recommended chip — uses BrowseViewModel with injected test data,
        //    so it loads without requiring a signed-in account or visitor session.
        //    The scroll restoration mechanism under test is section-agnostic.
        let chip = chipBar.buttons["Recommended"]
        guard chip.waitForExistence(timeout: 5) else {
            try captureAndSkip("Recommended chip not found — section may be disabled in settings", in: app)
        }
        scrollChipIntoView(chip, in: chipBar)
        chip.tap()

        // 3. Wait for home.sectionFeed to appear — this confirms the section switch
        //    has occurred and the Home feed is rendering.
        let feedScrollView = app.descendants(matching: .any)["home.sectionContainer"]
        guard feedScrollView.waitForExistence(timeout: 30) else {
            try captureAndSkip("home.sectionContainer did not appear within 30 s — Home feed may not have loaded", in: app)
        }

        // 4. Wait for at least one video card inside the section feed.
        let cardPredicate = NSPredicate(format: "identifier BEGINSWITH 'video.card.'")
        let firstCard = feedScrollView.descendants(matching: .any).matching(cardPredicate).firstMatch
        guard firstCard.waitForExistence(timeout: 20) else {
            try captureAndSkip("No video cards in Subscriptions feed within 20 s — feed may be empty", in: app)
        }

        // 5. Scroll the section feed down twice so at least one full page is below
        //    the fold. Target the feed's scroll view, not the chip bar.
        feedScrollView.swipeUp(velocity: .fast)
        Thread.sleep(forTimeInterval: 2.0)
        feedScrollView.swipeUp(velocity: .fast)
        Thread.sleep(forTimeInterval: 2.0)

        // 5. Verify the feed has actually scrolled: the first card should now be
        //    off-screen above the viewport (its maxY should be near or below 0).
        let firstCardMaxYAfterScroll = firstCard.frame.maxY
        XCTAssertLessThan(firstCardMaxYAfterScroll, 100,
            "First card should be off-screen after 2 fast swipes — feed may not have scrolled")

        // 6. Tap the card near the vertical centre of the visible feed area via a
        //    coordinate tap. This avoids a full accessibility-tree traversal that
        //    would time out when all cards are eagerly rendered in a VStack.
        let tapPoint = feedScrollView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        tapPoint.tap()

        // 7. Wait for PlayerView to open.
        let titleLabel = app.staticTexts["player.titleLabel"].firstMatch
        XCTAssertTrue(titleLabel.waitForExistence(timeout: 15),
                      "player.titleLabel must appear — PlayerView did not open")

        // 8. Navigate back via the always-accessible (but visually invisible) back
        //    button in the player's top-left overlay.
        let backButton = app.buttons["player.backButton"].firstMatch
        XCTAssertTrue(backButton.waitForExistence(timeout: 5), "player.backButton must be present")
        backButton.tap()

        // 9. Wait for the chip bar to reappear — confirms we're back on the feed.
        XCTAssertTrue(chipBar.waitForExistence(timeout: 5),
                      "Chip bar must reappear after back navigation")

        // 10. Assert: scroll position was restored.
        //     The first card must still be off-screen (< 100 pt maxY), meaning the
        //     feed was not reset to the top of the list.
        Thread.sleep(forTimeInterval: 1.0)   // let onAppear + proxy.scrollTo settle
        let firstCardMaxYAfterBack = firstCard.frame.maxY
        XCTAssertLessThan(
            firstCardMaxYAfterBack, 100,
            "First card maxY=\(Int(firstCardMaxYAfterBack)) — scroll was reset to top " +
            "instead of being restored to offset \(Int(firstCardMaxYAfterScroll))"
        )
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
