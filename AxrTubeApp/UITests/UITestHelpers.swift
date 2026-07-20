import XCTest

// MARK: - UITestHelpers
//
// Shared utilities reused across all UI test suites.
// Not a subclass of XCTestCase — import by value from any test file.
// Note: The enum body uses iOS-only XCUIElement APIs (tap, swipe, coordinate),
// so the entire declaration is excluded from the tvOS build.

#if !os(tvOS)
enum UITestHelpers {

    // MARK: - Tab navigation

    /// Taps the named tab, supporting both the bottom tab bar (iPhone) and the
    /// iPadOS 18 sidebar where tab items appear as standalone buttons.
    static func tapTab(named label: String, in app: XCUIApplication, timeout: TimeInterval = 5) {
        let tabBarButton = app.tabBars.buttons[label]
        if tabBarButton.waitForExistence(timeout: min(timeout, 3)) {
            let hittablePredicate = NSPredicate(format: "hittable == true")
            let hittableExpectation = XCTNSPredicateExpectation(predicate: hittablePredicate, object: tabBarButton)
            _ = XCTWaiter().wait(for: [hittableExpectation], timeout: timeout)
            tabBarButton.tap()
            return
        }
        let sidebarButton = app.buttons[label].firstMatch
        XCTAssertTrue(sidebarButton.waitForExistence(timeout: timeout),
                      "'\(label)' navigation item not found in tab bar or sidebar")
        let hittablePredicate = NSPredicate(format: "hittable == true")
        let hittableExpectation = XCTNSPredicateExpectation(predicate: hittablePredicate, object: sidebarButton)
        _ = XCTWaiter().wait(for: [hittableExpectation], timeout: timeout)
        sidebarButton.tap()
    }

    // MARK: - Chip bar scrolling

    /// Scrolls `chip` into the fully-visible area of `chipBar` before tapping.
    /// Uses coordinate drags on the chip bar itself, checking frame bounds so
    /// the chip is never scrolled past.
    static func scrollChipIntoView(_ chip: XCUIElement, in chipBar: XCUIElement, app: XCUIApplication) {
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

    // MARK: - Video cards

    /// Waits up to `timeout` for at least one `video.card.*` element to appear.
    /// Returns the first card element or `nil` if the feed stays empty.
    @discardableResult
    static func waitForVideoCards(in app: XCUIApplication, timeout: TimeInterval = 20) -> XCUIElement? {
        let predicate = NSPredicate(format: "identifier BEGINSWITH 'video.card.'")
        let cards = app.descendants(matching: .any).matching(predicate)
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count > 0"),
                                                    object: cards)
        guard XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed else {
            return nil
        }
        return cards.firstMatch
    }

    // MARK: - Player

    /// Taps `card` and waits for `player.titleLabel` to appear.
    /// Returns `true` when the player opened successfully within `timeout`.
    @discardableResult
    static func openPlayer(from card: XCUIElement, in app: XCUIApplication, timeout: TimeInterval = 15) -> Bool {
        card.tap()
        return app.staticTexts["player.titleLabel"].firstMatch.waitForExistence(timeout: timeout)
    }

    // MARK: - Scroll helpers

    /// Swipes up in `scrollView` until `element` exists and is hittable,
    /// or until `maxSwipes` attempts are exhausted.
    /// Waits up to `scrollViewTimeout` seconds for `scrollView` itself to appear
    /// before attempting any swipes — prevents "No matches found" on slow loads.
    ///
    /// Checking `isHittable` (not just `exists`) matters near the bottom of a
    /// scroll view: a row can already be present in the accessibility tree while
    /// still being visually covered by the tab bar, so taps on it land on the
    /// tab bar instead.
    static func scrollUntilVisible(_ element: XCUIElement,
                                   in scrollView: XCUIElement,
                                   maxSwipes: Int = 8,
                                   scrollViewTimeout: TimeInterval = 5) {
        guard scrollView.waitForExistence(timeout: scrollViewTimeout) else { return }
        var attempts = 0
        while (!element.exists || !element.isHittable) && attempts < maxSwipes {
            scrollView.swipeUp()
            attempts += 1
        }
    }

    // MARK: - Error assertions

    /// Fails the test if the standard "Error" feed alert is showing.
    static func assertNoErrorAlert(in app: XCUIApplication) {
        XCTAssertFalse(app.alerts["Error"].exists,
                       "An unexpected 'Error' alert is visible")
    }

    /// Fails the test if `player.errorBanner` is visible in `PlayerView`.
    static func assertNoPlayerErrorBanner(in app: XCUIApplication, videoTitle: String = "") {
        let banner = app.otherElements["player.errorBanner"].firstMatch
        let context = videoTitle.isEmpty ? "" : " during '\(videoTitle)'"
        XCTAssertFalse(banner.exists,
                       "player.errorBanner appeared\(context) — PlaybackViewModel.error was set")
    }

    /// Fails the test if `shorts.errorBanner` is visible in `ShortsPlayerView`.
    static func assertNoShortsErrorBanner(in app: XCUIApplication) {
        let banner = app.staticTexts["shorts.errorBanner"].firstMatch
        XCTAssertFalse(banner.exists,
                       "shorts.errorBanner appeared — PlaybackViewModel.error was set for the Short")
    }
}
#endif // !os(tvOS)

// MARK: - XCTestCase diagnostic helpers

extension XCTestCase {

    /// Captures a screenshot and accessibility-tree dump, attaches both with
    /// `keepAlways` lifetime, then throws `XCTSkip` with the given reason.
    ///
    /// The `throws -> Never` signature lets Swift treat every call site as a
    /// guaranteed scope-exit, so no trailing `return` is needed in guard-else blocks:
    ///
    ///     guard card.exists else {
    ///         try captureAndSkip("Feed empty — network issue", in: app)
    ///     }
    func captureAndSkip(
        _ reason: String,
        in app: XCUIApplication,
        file: StaticString = #file,
        line: UInt = #line
    ) throws -> Never {
        if app.state != .notRunning {
            let shot = app.screenshot()
            let shotAttachment = XCTAttachment(screenshot: shot)
            shotAttachment.name = "Skip state: \(reason.prefix(60))"
            shotAttachment.lifetime = .keepAlways
            add(shotAttachment)

            let treeAttachment = XCTAttachment(string: app.debugDescription)
            treeAttachment.name = "Accessibility tree at skip"
            treeAttachment.lifetime = .keepAlways
            add(treeAttachment)
        }

        throw XCTSkip(reason, file: file, line: line)
    }

    /// Captures a screenshot and accessibility-tree dump and attaches both with
    /// `keepAlways` lifetime. Call this immediately before an assertion that may
    /// fail to provide visual context in the result bundle.
    func captureState(_ label: String = "failure", in app: XCUIApplication) {
        guard app.state != .notRunning else { return }
        let shot = app.screenshot()
        let shotAttachment = XCTAttachment(screenshot: shot)
        shotAttachment.name = "Screenshot: \(label)"
        shotAttachment.lifetime = .keepAlways
        add(shotAttachment)

        let treeAttachment = XCTAttachment(string: app.debugDescription)
        treeAttachment.name = "Accessibility tree: \(label)"
        treeAttachment.lifetime = .keepAlways
        add(treeAttachment)
    }

    /// Polls for an element's existence while guarding against app crashes.
    /// Unlike `waitForExistence(timeout:)`, this checks `app.state` before each
    /// accessibility query so an unexpected process termination returns `false`
    /// instead of triggering XCTest's crash-detection mechanism, which terminates
    /// the entire test case even with `continueAfterFailure = true`.
    func waitForExistenceGuarded(
        _ element: XCUIElement,
        in app: XCUIApplication,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        let pollInterval: TimeInterval = 0.25
        repeat {
            guard app.state == .runningForeground || app.state == .runningBackground else {
                return false
            }
            if element.exists { return true }
            Thread.sleep(forTimeInterval: pollInterval)
        } while Date() < deadline
        guard app.state == .runningForeground || app.state == .runningBackground else {
            return false
        }
        return element.exists
    }
}
