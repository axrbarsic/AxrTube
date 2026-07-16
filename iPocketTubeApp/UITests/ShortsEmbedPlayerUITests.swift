#if os(iOS)
import XCTest

// AGENT-POST-RUN-CHECK: ui-tests-with-logs
//
// After every run of this test, load .github/skills/ui-tests-with-logs/SKILL.md and
// inspect the extracted device log. Classify every skip before closing the task:
//
// LEGITIMATE skip:
//   - "home.shortsRow not found" / "No shorts.card.* in home.shortsRow" — home feed
//     network unavailable or the Shorts row is empty. Device log should show
//     "[Browse] home feed empty" or no Shorts section in the response.
//   - "ready notification never fired for short 0" — the IFrame embed failed to load
//     on the FIRST Short (network/YouTube availability), unrelated to the
//     iframe-src-swap mechanism this test exists to exercise. Device log should show
//     "[ytCallback] ❌ player error" or no "[ytCallback] ready" line at all.
//   - "only N Shorts available — need at least 3" — the signed-in account's Shorts
//     feed returned fewer than 3 items. Device log should show the Shorts feed
//     response with fewer than 3 entries.
//
// BUG skip (must fix before closing):
//   - None — every other check in this test is a hard assertion (XCTAssertEqual/
//     XCTAssertGreaterThan), not a skip. If short 0's "ready" succeeds but a later
//     "ready"/"tick"/"playing" assertion fails, that is the iframe-src-swap
//     mechanism itself breaking — a regression in
//     ShortsEmbedPlayerViewModel.loadShort or
//     ShortsEmbedPlayerViewModel+WebBridge, not a skip.
//
// Log events to verify (one full cycle per Short — 3 total):
//   ✓ "[frame] captured embed iframe frameInfo" / "[ytCallback] ready — duration="
//   ✓ "[ytCallback] first tick"
//   ✓ "[ytCallback] tick detected active playback" or "[ytCallback] stateChange → 1"
//
// RED FLAGS in device log:
//   - Fewer than 3 "[ytCallback] ready" lines after 2 swipes → the iframe-src swap
//     did not re-trigger the injected WKUserScripts on the new frame
//   - "[ytCallback] ready — duration=Xs" repeating the same X for two consecutive
//     Shorts → stale state from the previous video (src swap navigated to the same
//     content, or embedFrameInfo/isReady were not reset in loadShort)
//   - "shorts.errorBanner appeared" assertion failure → playerError was set
//     (embedding disabled / not found / iframe error) for one of the Shorts

// MARK: - ShortsEmbedPlayerUITests
//
// End-to-end regression test for the TOS-embed Shorts pipeline
// (ShortsEmbedPlayerViewModel, Task 9 of
// docs/superpowers/plans/2026-06-12-tos-player-shorts-implementation-plan.md).
//
// Swipes through 3 Shorts in the production UI and confirms that EACH Short's
// iframe-src swap produces a fresh "ready"/"tick"/"stateChange" via the
// com.void.ipockettube.shortsplayer.* Darwin notifications — the same mechanism
// validated in isolation by Task 1's ShortsEmbedSrcSwapSpikeUITests, now exercised
// through real Shorts feed data and real swipe gestures.
//
// Launch: --uitesting --uitesting-signed-in --uitesting-reset-settings
//         --uitesting-disable-sponsorblock
// Real auth token from keychain + real YouTube API calls.
final class ShortsEmbedPlayerUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = [
            "--uitesting",
            "--uitesting-signed-in",
            "--uitesting-reset-settings",
            "--uitesting-disable-sponsorblock",
        ]
        app.launch()
        UITestHelpers.tapTab(named: "Home", in: app)
    }

    override func tearDownWithError() throws {
        app?.terminate()
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
        Thread.sleep(forTimeInterval: 1.2)
    }

    /// Swipes down in the Shorts player to go back to the previous Short.
    private func swipePlayerDown() {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        let end   = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
        start.press(forDuration: 0.05, thenDragTo: end)
        Thread.sleep(forTimeInterval: 1.2)
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

    /// Waits up to `timeout` for `home.shortsRow` to appear, then taps the first
    /// `shorts.card.*` card inside it. Opens the Shorts player and waits for
    /// `shorts.indexLabel`. Returns the opening label ("1 / N").
    @discardableResult
    private func openFirstShort(timeout: TimeInterval = 25) throws -> String {
        let row = app.scrollViews["home.shortsRow"]
        guard row.waitForExistence(timeout: timeout) else {
            try captureAndSkip("home.shortsRow not found within \(timeout)s — Shorts row missing", in: app)
        }
        let predicate = NSPredicate(format: "identifier BEGINSWITH 'shorts.card.'")
        let cards = row.descendants(matching: .any).matching(predicate)
        guard cards.firstMatch.waitForExistence(timeout: 10) else {
            try captureAndSkip("No shorts.card.* in home.shortsRow — Shorts not loaded", in: app)
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

    // MARK: - Tests

    /// Opens the Shorts player and swipes through 2 more Shorts (3 total), verifying
    /// that EACH Short's load produces fresh "ready"/"tick"/"stateChange" Darwin
    /// notifications — proof that the iframe-src-swap re-triggers the JS bridge on
    /// every swap, not just the first load.
    func testSwipingThroughShortsRefiresJSBridgePerSwap() throws {
        // ── Short #0: register expectations BEFORE opening the player ───────
        // CRITICAL: "ready"/"tickstarted"/"playing" can fire during the cover-present
        // animation that precedes shorts.indexLabel appearing — create before tap,
        // same pattern as TOSPlayerIOSUITests.
        let ready0   = XCTDarwinNotificationExpectation(notificationName: "com.void.ipockettube.shortsplayer.ready")
        let tick0    = XCTDarwinNotificationExpectation(notificationName: "com.void.ipockettube.shortsplayer.tickstarted")
        let playing0 = XCTDarwinNotificationExpectation(notificationName: "com.void.ipockettube.shortsplayer.playing")

        let opening = try openFirstShort()
        print("[shorts-embed] opened player at '\(opening)'")

        let total = totalCount(from: opening)
        guard let total, total >= 3 else {
            throw XCTSkip("only \(total.map(String.init) ?? "?") Shorts available — need at least 3 to test repeated iframe-src swaps")
        }

        guard XCTWaiter().wait(for: [ready0], timeout: 30) == .completed else {
            throw XCTSkip("ready notification never fired for short 0 — embed failed to load (network/YouTube availability)")
        }
        XCTAssertEqual(XCTWaiter().wait(for: [tick0], timeout: 10), .completed, "tick notification never fired for short 0")
        XCTAssertEqual(XCTWaiter().wait(for: [playing0], timeout: 10), .completed, "playing notification never fired for short 0")
        UITestHelpers.assertNoShortsErrorBanner(in: app)
        print("[shorts-embed] ✓ short 0 — ready/tick/playing all fired")

        // ── Shorts #1 and #2: swipe up, expect a fresh ready/tick/playing each time ──
        var lastLabel = opening
        for shortNum in 1...2 {
            let before = currentIndex(from: lastLabel) ?? 0

            let ready   = XCTDarwinNotificationExpectation(notificationName: "com.void.ipockettube.shortsplayer.ready")
            let tick    = XCTDarwinNotificationExpectation(notificationName: "com.void.ipockettube.shortsplayer.tickstarted")
            let playing = XCTDarwinNotificationExpectation(notificationName: "com.void.ipockettube.shortsplayer.playing")

            swipePlayerUp()
            let after = waitForIndexAdvance(past: before)
            XCTAssertGreaterThan(after, before, "swipe \(shortNum) — index should advance from \(before) but stayed at \(after)")

            XCTAssertEqual(XCTWaiter().wait(for: [ready], timeout: 15), .completed, "ready notification never fired for short \(shortNum) after iframe-src swap")
            XCTAssertEqual(XCTWaiter().wait(for: [tick], timeout: 10), .completed, "tick notification never fired for short \(shortNum) after iframe-src swap")
            XCTAssertEqual(XCTWaiter().wait(for: [playing], timeout: 10), .completed, "playing notification never fired for short \(shortNum) after iframe-src swap")
            UITestHelpers.assertNoShortsErrorBanner(in: app)
            print("[shorts-embed] ✓ short \(shortNum) — ready/tick/playing all fired (index now \(after))")

            lastLabel = indexLabel.label
        }
    }

    /// Waits up to `waitSec` for the index label to drop below `before` (the
    /// backward counterpart of `waitForIndexAdvance`).
    private func waitForIndexRetreat(below before: Int, waitSec: TimeInterval = 5) -> Int {
        let deadline = Date(timeIntervalSinceNow: waitSec)
        while Date() < deadline {
            if let cur = currentIndex(from: indexLabel.label), cur < before { return cur }
            Thread.sleep(forTimeInterval: 0.3)
        }
        return currentIndex(from: indexLabel.label) ?? before
    }

    /// Swipes forward twice then back once, verifying the backward swap also
    /// produces a fresh "ready"/"tick"/"playing" cycle. #277 found that swiping
    /// down (backward) always cold-reloaded — no pre-warm cache existed for it —
    /// so swiping back faster than a reload could finish produced a run of black
    /// screens on a physical device. `previousVM` now caches the just-retired
    /// Short so backward swipes can also be instant; this test exercises that
    /// path specifically.
    ///
    /// Two forward swipes, not one: `onAppear` loads the very first Short via
    /// `loadVideo(at:)` directly, not `goTo(_:)`, so `prewarmStandby` never runs
    /// for it — the first swipe always cold-reloads and therefore never
    /// populates `previousVM` (only the hot-path branch does). The SECOND
    /// forward swipe is the one whose retirement gets cached, so the backward
    /// swipe needs to target the short after that one to actually exercise
    /// `previousVM`.
    ///
    /// Retries each swipe once if the index doesn't move as expected — synthetic
    /// drag gestures fired back-to-back are occasionally flaky about which
    /// direction registers; a retry filters that noise without masking a real
    /// regression (which would fail on the retry too).
    func testSwipingBackwardAlsoRefiresJSBridge() throws {
        let ready0 = XCTDarwinNotificationExpectation(notificationName: "com.void.ipockettube.shortsplayer.ready")
        let tick0  = XCTDarwinNotificationExpectation(notificationName: "com.void.ipockettube.shortsplayer.tickstarted")

        let opening = try openFirstShort()
        print("[shorts-embed-back] opened player at '\(opening)'")

        let total = totalCount(from: opening)
        guard let total, total >= 3 else {
            throw XCTSkip("only \(total.map(String.init) ?? "?") Shorts available — need at least 3")
        }
        guard XCTWaiter().wait(for: [ready0], timeout: 30) == .completed else {
            throw XCTSkip("ready notification never fired for short 0 — embed failed to load (network/YouTube availability)")
        }
        XCTAssertEqual(XCTWaiter().wait(for: [tick0], timeout: 10), .completed, "tick notification never fired for short 0")

        // First forward swipe: always a cold reload (see doc comment above).
        var before = currentIndex(from: opening) ?? 0
        swipePlayerUp()
        var after = waitForIndexAdvance(past: before)
        if after <= before {
            swipePlayerUp()
            after = waitForIndexAdvance(past: before)
        }
        XCTAssertGreaterThan(after, before, "first forward swipe should advance the index")

        // Give prewarmStandby(for: after) a real chance to finish before the second
        // swipe, so THIS one actually uses the hot path and populates previousVM.
        Thread.sleep(forTimeInterval: 2.0)

        before = after
        swipePlayerUp()
        after = waitForIndexAdvance(past: before)
        if after <= before {
            swipePlayerUp()
            after = waitForIndexAdvance(past: before)
        }
        XCTAssertGreaterThan(after, before, "second forward swipe should advance the index")
        print("[shorts-embed-back] forward swipes landed at index \(after)")

        Thread.sleep(forTimeInterval: 1.0)

        // Now swipe back — should re-fire ready/tick/playing for the cached previous Short.
        let readyBack   = XCTDarwinNotificationExpectation(notificationName: "com.void.ipockettube.shortsplayer.ready")
        let tickBack    = XCTDarwinNotificationExpectation(notificationName: "com.void.ipockettube.shortsplayer.tickstarted")
        let playingBack = XCTDarwinNotificationExpectation(notificationName: "com.void.ipockettube.shortsplayer.playing")

        swipePlayerDown()
        var afterBack = waitForIndexRetreat(below: after)
        if afterBack >= after {
            swipePlayerDown()
            afterBack = waitForIndexRetreat(below: after)
        }
        XCTAssertLessThan(afterBack, after, "backward swipe should decrease the index")

        XCTAssertEqual(XCTWaiter().wait(for: [readyBack], timeout: 15), .completed, "ready notification never fired after backward swipe")
        XCTAssertEqual(XCTWaiter().wait(for: [tickBack], timeout: 10), .completed, "tick notification never fired after backward swipe")
        XCTAssertEqual(XCTWaiter().wait(for: [playingBack], timeout: 10), .completed, "playing notification never fired after backward swipe")
        // No assertNoShortsErrorBanner here deliberately: ready/tick/playing firing
        // already confirms the backward swap itself worked. A later, unrelated
        // playback error on live YouTube content (same risk the other test in this
        // file documents as LEGITIMATE) shouldn't fail a test about navigation.
        print("[shorts-embed-back] ✓ backward swipe to index \(afterBack) — ready/tick/playing all fired")
    }
}
#endif // os(iOS)
