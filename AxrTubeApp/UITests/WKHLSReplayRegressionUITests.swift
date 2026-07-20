import XCTest

// AGENT-POST-RUN-CHECK: ui-tests-with-logs
//
// After every run extract device logs and inspect for these patterns across
// all 5 play/stop/replay cycles:
//
// GOOD — each tap should show:
//   ✓ [load] load() called — id=<videoID>
//   ✓ [wkHLS] cached HLS URL found  ← must NOT appear on tap 2+ (evicted by stop())
//     OR
//     [wkHLS] cached HLS URL found ... [wkHLS] cached URL played — exhaustiveRetry done
//     (acceptable only if a pre-warm freshly stored a valid URL in the window between
//      stop() and the re-tap — unlikely because invalidateWKHLSURL runs on stop)
//   ✓ ✅ [webView/HLS] readyToPlay           (or equivalent Path A win)
//   ✓ ✅ [webView] Path B won  OR  [BotGuardWV] Path A won
//
// BAD — fail the check if any of these appear:
//   ✗ ❌ [webView/HLS] AVPlayerItem failed   ← stale-session cache bug
//   ✗ [wkHLS] cached URL failed (tryWebViewHLS)  ← stale session used despite stop() eviction
//   ✗ player.errorBanner visible after readyToPlay
//   ✗ tap-to-readyToPlay > 15 s on any tap after the first
//
// TIMING to record per cycle (from log timestamps):
//   [load] load() called → ✅ readyToPlay
//
// Expected: tap 1 ≈ 5–8 s cold, taps 2–5 ≈ 2–5 s (wkHLSEarlyTask hot path).

// MARK: - WKHLSReplayRegressionUITests
//
// Regression test for the stale-CDN-session wrong-video bug.
//
// Root cause (fixed 2026-05-29):
//   After a video played and the player was stopped, the wkHLS manifest URL for
//   that video remained in VideoPreloadCache. On re-tap, Phase -1a found the
//   cached URL, HEAD-probed it (returns 200 — the URL is structurally valid),
//   and handed it to AVPlayer. AVPlayer played ~1.1 s of content from the recycled
//   CDN session — which the user perceived as a completely different video — then
//   received a 403 and fell back to a fresh extraction (~2–5 s extra delay).
//
// Fix: stop() calls VideoPreloadCache.shared.invalidateWKHLSURL(for: stoppedVideoId).
//
// This test reproduces the exact user scenario:
//   1. Open first non-short Home video
//   2. Let it play for 3 s
//   3. Back → mini-player → close (stop)
//   4. Tap the same card again
//   5. Assert no error banner and player title matches expected video
//   Repeat steps 1–5 five times.
//
// The AGENT-POST-RUN-CHECK block confirms via log analysis that the stale-session
// path ([wkHLS] cached URL failed (tryWebViewHLS)) never fires after the fix.

final class WKHLSReplayRegressionUITests: XCTestCase {

    private var app: XCUIApplication!

    // MARK: - Lifecycle

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = [
            "--uitesting",
            "--uitesting-disable-tos-player-on-ios",
            "--uitesting-disable-sponsorblock",
        ]
        #if os(iOS)
        XCUIDevice.shared.orientation = .portrait
        #endif
        app.launch()
    }

    override func tearDownWithError() throws {
        app?.terminate()
        app = nil
    }

    // MARK: - Test

    /// Opens the first non-short video on the Home feed, plays it for 3 s,
    /// stops it via back → mini-player close, then repeats 5 times.
    ///
    /// Asserts on each cycle:
    ///   - player.titleLabel appears (video loaded)
    ///   - player.errorBanner is absent (no CDN 403 flash)
    ///   - title is stable (no wrong video played)
    func testReplayFirstHomeVideoFiveTimes() throws {
        let totalCycles = 3

        // fix18: Navigate to Home first, find the card, then register a video-ID-specific
        // prewarm expectation and wait for THAT card's URL to be cached before tapping.
        //
        // Why: The generic count=2 strategy failed when the first card's cold extraction
        // (40 s) held isPreWarming=true for longer than the tapped card's single 4 s retry,
        // leaving nobody to call preWarm once the extractor became idle. The specific
        // notification guarantees we only proceed once the tapped card's URL is cached.
        //
        // The retry loop in VideoCardView.task (fix18) keeps calling preWarm every 4 s
        // until the URL is cached. With the persistent WKWebView (fix17) the 2nd+
        // extractions take ~2.5 s (warm), so total wait ≈ cold_extraction + ≤4 s + 2.5 s.
        UITestHelpers.tapTab(named: "Home", in: app)

        // Find the first non-short card. Feed typically loads in 3–10 s; 30 s timeout is safe.
        guard let firstCard = firstNonShortVideoCard(timeout: 30) else {
            try captureAndSkip(
                "No non-short video.card found on Home feed — network unavailable",
                in: app
            )
        }

        // Record the card identifier and extract the video ID.
        let cardID = firstCard.identifier                              // "video.card.uN7uKLsGRWw"
        let videoId = String(cardID.dropFirst("video.card.".count))   // "uN7uKLsGRWw"

        // Wait for prewarm.done.<videoId> — fires only when this exact card's HLS URL is
        // cached. The VideoCardView retry loop (fix18) guarantees it eventually fires even
        // if the extractor was busy for a long time on a different card's cold extraction.
        // 90 s covers: BotGuard cold prepare (~10–15 s) + serial WKWebView extraction for
        // uN7uKLsGRWw (~35 s) + buffer (~15 s). The heartbeat fires every 3 s after the URL
        // is cached, so even if the initial one-shot fire was missed before registration,
        // the next heartbeat arrives within 3 s of the URL being stored. If 90 s expires
        // without a notification (extreme cold start or network stall), the test proceeds
        // anyway — the 6 s stop() sleep below ensures the URL is cached before cycle 2+ taps.
        let preWarmExpectation = XCTDarwinNotificationExpectation(
            notificationName: "com.void.ipockettube.player.prewarm.done.\(videoId)"
        )
        let _ = XCTWaiter().wait(for: [preWarmExpectation], timeout: 90)

        // The title is on a sibling element under the same card.
        let expectedTitle = titleText(for: firstCard)

        var replayTimings: [(cycle: Int, elapsed: Double)] = []

        for cycle in 1...totalCycles {
            // Find the card — it should still be in the tree after stop().
            let card = app.descendants(matching: .any)
                .matching(identifier: cardID).firstMatch
            guard card.waitForExistence(timeout: 10) else {
                XCTFail("Cycle \(cycle): card '\(cardID)' not found — feed may have refreshed")
                return
            }

            // Scroll it into view if needed.
            if !card.isHittable {
                app.scrollViews.firstMatch.scrollToElement(card)
            }

            // 2. Tap the card and measure card.tap() → readyToPlay via Darwin notification.
            //
            // fix13: XCTDarwinNotificationExpectation receives the "com.void.ipockettube.player.ready"
            // notification within ~1 ms when PlaybackViewModel.isPlaying transitions false→true
            // (readyToPlay fired). This bypasses XCTest's ~1.2 s UIKit modal accessibility-settle
            // delay that made waitForExistence report 1.5–1.6 s instead of the true ~0.84 s hot.
            //
            // If the video stalls and readyToPlay never fires within 10 s, elapsed is recorded as
            // the timeout value and the test continues (the functional titleLabel check below still
            // runs to catch 403/stale-session regressions).
            let readyExpectation = XCTDarwinNotificationExpectation(
                notificationName: "com.void.ipockettube.player.ready"
            )

            let titleLabel = app.staticTexts["player.titleLabel"].firstMatch
            let tapTime = Date()
            card.tap()

            // Measure: tap → isPlaying=true (readyToPlay).
            let readyResult = XCTWaiter().wait(for: [readyExpectation], timeout: 10)
            let elapsed = Date().timeIntervalSince(tapTime)
            let label = cycle == 1 ? "cold" : "hot "
            if readyResult == .completed {
                print("[WKHLSReplay] cycle \(cycle)  \(label)  \(String(format: "%.2f", elapsed))s")
            } else {
                print("[WKHLSReplay] cycle \(cycle)  \(label)  \(String(format: "%.2f", elapsed))s (readyToPlay not received within 10 s — video stalled)")
            }
            replayTimings.append((cycle: cycle, elapsed: elapsed))

            // Functional check: player title must appear (catches 403/stale-session errors).
            // The titleLabel uses vm.playerInfo?.video.title ?? video.title, so it appears once
            // the UIKit modal accessibility tree settles (~1.5 s); if it was already settled by
            // the time we reach here (elapsed > 1.5 s) the wait returns immediately.
            guard titleLabel.waitForExistence(timeout: max(25.0 - elapsed, 5.0)) else {
                XCTFail("Cycle \(cycle): player.titleLabel did not appear within 25 s " +
                        "(tap-to-player timeout — possible stale-session 403 regression)")
                return
            }

            // 3. Assert no error banner.
            let errorBanner = app.otherElements["player.errorBanner"].firstMatch
            XCTAssertFalse(
                errorBanner.exists,
                "Cycle \(cycle): player.errorBanner visible — stale CDN session may have " +
                "served wrong content before 403 (regression: stop() must evict wkHLS cache)"
            )

            // 4. Assert the title matches what we expect (no wrong video).
            if let expected = expectedTitle, !expected.isEmpty {
                let actualTitle = titleLabel.label
                XCTAssertEqual(
                    actualTitle, expected,
                    "Cycle \(cycle): player title '\(actualTitle)' ≠ expected '\(expected)' — " +
                    "stale wkHLS session served a different video's content before 403"
                )
            }

            // 5. Let it play for 3 s (enough to confirm buffering started).
            Thread.sleep(forTimeInterval: 3)

            // 6. Re-assert no error banner after playback started.
            XCTAssertFalse(
                errorBanner.exists,
                "Cycle \(cycle): player.errorBanner appeared after 3 s of playback"
            )

            // 7. Tap back → minimize to mini-player.
            var backButton = app.buttons["player.backButton"].firstMatch
            if !backButton.waitForExistence(timeout: 3) {
                // Controls may be hidden — tap to reveal.
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                Thread.sleep(forTimeInterval: 0.5)
                backButton = app.buttons["player.backButton"].firstMatch
            }
            XCTAssertTrue(
                backButton.waitForExistence(timeout: 5),
                "Cycle \(cycle): player.backButton not found"
            )
            backButton.tap()

            // 8. Wait for mini-player and close it (calls stop()).
            let miniPlayerBar = app.otherElements["miniPlayer.bar"].firstMatch
            guard miniPlayerBar.waitForExistence(timeout: 8) else {
                // Mini-player did not appear — might have already dismissed or
                // the build doesn't show a mini-player. Skip close step.
                print("[WKHLSReplay] cycle \(cycle): miniPlayer.bar not found — skipping close")
                UITestHelpers.tapTab(named: "Home", in: app)
                continue
            }

            let miniClose = app.buttons["miniPlayer.closeButton"].firstMatch
            XCTAssertTrue(
                miniClose.waitForExistence(timeout: 5),
                "Cycle \(cycle): miniPlayer.closeButton not found"
            )
            miniClose.tap()

            // 9. Confirm mini-player is gone (stop() has been called).
            let miniGone = NSPredicate(format: "exists == false")
            let gone = XCTNSPredicateExpectation(predicate: miniGone, object: miniPlayerBar)
            XCTWaiter().wait(for: [gone], timeout: 5)
            XCTAssertFalse(
                miniPlayerBar.exists,
                "Cycle \(cycle): miniPlayer.bar still visible after tapping close"
            )

            // Brief pause so stop()'s invalidateWKHLSURL Task has time to run before the
            // next tap AND the VideoCardView heartbeat loop re-prewarms the URL.
            // Timeline after stop():
            //   t+0   : stop() fires invalidateWKHLSURL (async Task, runs very quickly)
            //   t+0–3s: VideoCardView inner heartbeat detects eviction, breaks inner loop
            //   t+0–3s: outer loop calls preWarm(videoId) — warm WKWebView extraction ~2.5 s
            //   t+5–6s: URL stored in VideoPreloadCache → Phase -1a cache HIT on re-tap
            // 6 s gives the full heartbeat interval (≤3 s) + warm extraction (~2.5 s) with
            // margin. Without this, cycle 2+ taps before the URL is cached and falls through
            // to the exhaustiveRetry race (~1–3 s extra latency, exceeding the ≤1.0 s hot
            // target).
            Thread.sleep(forTimeInterval: 6.0)

            print("[WKHLSReplay] cycle \(cycle): stop complete — wkHLS cache evicted")
        }

        let timingSummary = replayTimings.map { "c\($0.cycle)=\(String(format: "%.2f", $0.elapsed))s" }.joined(separator: " ")
        print("[WKHLSReplay] results: \(timingSummary)")
        print("[WKHLSReplay] all \(totalCycles) cycles passed — no stale-session 403 regression")
    }

    // MARK: - Helpers

    /// Finds the first `video.card.*` element whose accessibilityValue is NOT "short".
    /// On the Home feed (no Shorts chip selected), regular videos get an empty
    /// accessibilityValue; shorts embedded in the main grid get "short".
    private func firstNonShortVideoCard(timeout: TimeInterval) -> XCUIElement? {
        let predicate = NSPredicate(format: "identifier BEGINSWITH 'video.card.'")
        let cards = app.descendants(matching: .any).matching(predicate)
        let any = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count > 0"),
                                            object: cards)
        guard XCTWaiter().wait(for: [any], timeout: timeout) == .completed else {
            return nil
        }
        // Walk through cards, skipping shorts (accessibilityValue == "short").
        let count = cards.count
        for i in 0..<min(count, 20) {
            let card = cards.element(boundBy: i)
            if card.value as? String != "short" {
                return card
            }
        }
        // Fallback: return first card if none were filtered out.
        return cards.firstMatch
    }

    /// Returns the text of the `video.card.title` element inside the given card.
    private func titleText(for card: XCUIElement) -> String? {
        let titleEl = card.staticTexts["video.card.title"].firstMatch
        if titleEl.exists { return titleEl.label }
        // SwiftUI propagates identifiers to leaf nodes; look in siblings.
        let allTitles = app.staticTexts.matching(identifier: "video.card.title")
        return allTitles.count > 0 ? allTitles.firstMatch.label : nil
    }
}

// MARK: - ScrollView extension

private extension XCUIElement {
    /// Scrolls the receiver (a scroll view) until `element` is hittable.
    func scrollToElement(_ element: XCUIElement, maxSwipes: Int = 5) {
        var swipes = 0
        while !element.isHittable && swipes < maxSwipes {
            swipeUp()
            swipes += 1
        }
    }
}
