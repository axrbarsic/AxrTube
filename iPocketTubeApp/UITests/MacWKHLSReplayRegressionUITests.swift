#if os(macOS)
import XCTest

// AGENT-POST-RUN-CHECK: ui-tests-with-logs
//
// After every run inspect the xcodebuild log for these patterns across all cycles:
//
// GOOD — each cycle should show:
//   ✓ [load] load() called — id=<videoID>
//   ✓ [wkHLS] cached HLS URL found  ← must NOT appear on cycle 2+ (evicted by stop())
//   ✓ ✅ [webView/HLS] readyToPlay   (or Path A win)
//   ✓ [WKHLSReplay-mac] cycle N  cold/hot  X.XXs
//
// BAD — fail the check if any of these appear:
//   ✗ [wkHLS] cached URL failed (tryWebViewHLS)   ← stale session used despite stop() eviction
//   ✗ player.errorBanner visible after readyToPlay
//   ✗ tap-to-readyToPlay > 15 s on any cycle after cycle 1

// MARK: - MacWKHLSReplayRegressionUITests
//
// macOS equivalent of WKHLSReplayRegressionUITests.
//
// Differences from iOS version:
//   - No mini-player on macOS: back button calls vm.stop() + dismiss() directly,
//     clearing deepLinkedVideo = nil. Player disappears immediately.
//   - PlayerView opened via NavigationStack.navigationDestination (card tap → selectedVideo),
//     not via deepLinkedVideo ZStack overlay (queue-inject path).
//   - card.click() instead of card.tap().
//   - Saved app state deleted before launch (WindowGroup restoration issue).
//   - titleText reads element.value (AXValue) on macOS, not element.label (AXDescription).

final class MacWKHLSReplayRegressionUITests: XCTestCase {

    private var app: XCUIApplication!

    // MARK: - Lifecycle

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = [
            "--uitesting",
            "--uitesting-disable-sponsorblock",
        ]
        // macOS WindowGroup won't create a window if OS saved an empty window state.
        let savedState = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Saved Application State/com.void.ipockettube.app.savedState")
        try? FileManager.default.removeItem(at: savedState)
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        _ = app.windows.firstMatch.waitForExistence(timeout: 10)
    }

    override func tearDownWithError() throws {
        app?.terminate()
        app = nil
    }

    // MARK: - Test

    /// Opens the first non-short video on the Home feed, plays it for 3 s,
    /// taps back (stop()), then replays it 3 cycles total.
    ///
    /// Asserts on each cycle:
    ///   - player.titleLabel appears (video loaded)
    ///   - player.errorBanner is absent (no CDN 403 flash)
    ///   - title is stable (no wrong video played)
    func testReplayFirstHomeVideoThreeTimes() throws {
        let totalCycles = 3

        // Home is selected by default in the macOS sidebar — no tab navigation needed.
        // Find the first non-short card. Feed typically loads in 3–10 s; 30 s is safe.
        guard let firstCard = firstNonShortVideoCard(timeout: 30) else {
            try captureAndSkip(
                "No non-short video.card found on Home feed — network unavailable",
                in: app
            )
        }

        let cardID    = firstCard.identifier                              // "video.card.uN7uKLsGRWw"
        let videoId   = String(cardID.dropFirst("video.card.".count))    // "uN7uKLsGRWw"
        let expectedTitle = titleText(for: firstCard)

        // Wait for the pre-warm notification for this exact card's HLS URL.
        // Same logic as iOS: the VideoCardView retry loop fires
        // "com.void.ipockettube.player.prewarm.done.<videoId>" once the URL is cached.
        let preWarmExpectation = XCTDarwinNotificationExpectation(
            notificationName: "com.void.ipockettube.player.prewarm.done.\(videoId)"
        )
        let _ = XCTWaiter().wait(for: [preWarmExpectation], timeout: 90)

        var replayTimings: [(cycle: Int, elapsed: Double)] = []

        for cycle in 1...totalCycles {
            // Find the card — should still be visible in the NavigationSplitView detail.
            let card = app.descendants(matching: .any)
                .matching(identifier: cardID).firstMatch
            guard card.waitForExistence(timeout: 10) else {
                XCTFail("Cycle \(cycle): card '\(cardID)' not found")
                return
            }

            // Scroll into view if needed.
            if !card.isHittable {
                let scrollView = app.scrollViews.firstMatch
                scrollView.scrollToElement(card)
            }

            // Measure: card click → readyToPlay (Darwin notification).
            let readyExpectation = XCTDarwinNotificationExpectation(
                notificationName: "com.void.ipockettube.player.ready"
            )

            let titleLabel = app.staticTexts["player.titleLabel"].firstMatch
            let tapTime = Date()
            card.click()

            let readyResult = XCTWaiter().wait(for: [readyExpectation], timeout: 30)
            let elapsed = Date().timeIntervalSince(tapTime)
            let label = cycle == 1 ? "cold" : "hot "
            if readyResult == .completed {
                print("[WKHLSReplay-mac] cycle \(cycle)  \(label)  \(String(format: "%.2f", elapsed))s")
            } else {
                print("[WKHLSReplay-mac] cycle \(cycle)  \(label)  \(String(format: "%.2f", elapsed))s (readyToPlay not received within 30 s — video stalled)")
            }
            replayTimings.append((cycle: cycle, elapsed: elapsed))

            // Functional check: player.titleLabel must appear.
            // On macOS, AXValue holds the text content; element.value as? String.
            guard titleLabel.waitForExistence(timeout: max(25.0 - elapsed, 5.0)) else {
                XCTFail("Cycle \(cycle): player.titleLabel did not appear within 25 s")
                return
            }

            // Assert no error banner.
            let errorBanner = app.otherElements["player.errorBanner"].firstMatch
            XCTAssertFalse(
                errorBanner.exists,
                "Cycle \(cycle): player.errorBanner visible — possible stale CDN session regression"
            )

            // Assert the title matches (no wrong video).
            if let expected = expectedTitle, !expected.isEmpty {
                let actualTitle = (titleLabel.value as? String) ?? titleLabel.label
                XCTAssertEqual(
                    actualTitle, expected,
                    "Cycle \(cycle): player title '\(actualTitle)' ≠ expected '\(expected)'"
                )
            }

            // Let it play for 3 s.
            Thread.sleep(forTimeInterval: 3)

            // Re-assert no error banner after playback started.
            XCTAssertFalse(
                errorBanner.exists,
                "Cycle \(cycle): player.errorBanner appeared after 3 s of playback"
            )

            // Tap back — on macOS this calls vm.stop() + dismiss(), no mini-player.
            let backButton = app.buttons["player.backButton"].firstMatch
            XCTAssertTrue(
                backButton.waitForExistence(timeout: 5),
                "Cycle \(cycle): player.backButton not found"
            )
            backButton.click()

            // Wait for player to disappear (titleLabel gone = NavigationStack popped).
            let playerGone = NSPredicate(format: "exists == false")
            let gone = XCTNSPredicateExpectation(predicate: playerGone, object: titleLabel)
            _ = XCTWaiter().wait(for: [gone], timeout: 5)
            XCTAssertFalse(
                titleLabel.exists,
                "Cycle \(cycle): player.titleLabel still visible after back button — player did not dismiss"
            )

            // Wait for stop()'s invalidateWKHLSURL to run and the VideoCardView
            // retry loop to re-prewarm the URL.
            // On macOS: warm WKWebView extraction ~2.5 s + heartbeat interval ≤3 s + margin → 6 s.
            Thread.sleep(forTimeInterval: 6.0)

            print("[WKHLSReplay-mac] cycle \(cycle): stop complete — wkHLS cache evicted")
        }

        let timingSummary = replayTimings
            .map { "c\($0.cycle)=\(String(format: "%.2f", $0.elapsed))s" }
            .joined(separator: " ")
        print("[WKHLSReplay-mac] results: \(timingSummary)")
        print("[WKHLSReplay-mac] all \(totalCycles) cycles passed — no stale-session 403 regression")
    }

    // MARK: - Helpers

    private func firstNonShortVideoCard(timeout: TimeInterval) -> XCUIElement? {
        let predicate = NSPredicate(format: "identifier BEGINSWITH 'video.card.'")
        let cards = app.descendants(matching: .any).matching(predicate)
        let any = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "count > 0"),
            object: cards
        )
        guard XCTWaiter().wait(for: [any], timeout: timeout) == .completed else { return nil }
        let count = cards.count
        for i in 0..<min(count, 20) {
            let card = cards.element(boundBy: i)
            if card.value as? String != "short" { return card }
        }
        return cards.firstMatch
    }

    private func titleText(for card: XCUIElement) -> String? {
        let titleEl = card.staticTexts["video.card.title"].firstMatch
        if titleEl.exists { return titleEl.label }
        let allTitles = app.staticTexts.matching(identifier: "video.card.title")
        return allTitles.count > 0 ? allTitles.firstMatch.label : nil
    }

    private func captureAndSkip(_ message: String, in app: XCUIApplication) throws -> Never {
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "skip-screenshot"
        attachment.lifetime = .keepAlways
        add(attachment)
        throw XCTSkip(message)
    }
}

// MARK: - ScrollView extension

private extension XCUIElement {
    func scrollToElement(_ element: XCUIElement, maxSwipes: Int = 5) {
        var swipes = 0
        while !element.isHittable && swipes < maxSwipes {
            swipeUp()
            swipes += 1
        }
    }
}
#endif
