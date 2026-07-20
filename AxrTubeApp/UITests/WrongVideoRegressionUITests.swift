import XCTest

// MARK: - WrongVideoRegressionUITests
//
// Regression test for the "wrong video played" bug — where tapping a video card
// in the Home feed causes the player to load a *different* video than the one
// whose card was tapped.
//
// Scenario (four sequential play/dismiss cycles from the live Home feed):
//   1. Open Home.  Identify the first and third non-Shorts video cards by ID.
//   2. Play video #1  [play#1]  — tap its card, wait for player.titleLabel
//   3. Back → dismiss mini-player → return to Home feed
//   4. Play video #1  [play#2]  — same card, second time
//   5. Back → dismiss mini-player → return to Home feed
//   6. Play video #3  [play#3]  — the third distinct non-Short card in the feed
//   7. Back → dismiss mini-player → return to Home feed
//   8. Play video #1  [play#4]  — first video one final time
//
// Each play attempt prints:
//   [wrongvideo] play#N expected=<videoId>
// to the test log so the post-run log analysis can confirm the correct video
// was loaded by matching against the app's own [load] log lines.

// AGENT-POST-RUN-CHECK: ui-tests-with-logs
//
// After the run, extract device/app logs and verify each play loaded the
// correct video:
//
//   # All play attempts from the test (expected IDs)
//   grep '\[wrongvideo\]' "$APP_LOG"
//
//   # Actual video IDs loaded by the app
//   grep '\[load\] load() called' "$APP_LOG"
//
// For each play#N expected=XXXXX there must be a subsequent
//   [load] load() called — id=XXXXX
// with the SAME ID.
//
// EXPECTED (no bug):
//   play#1 expected=XXXXXX  →  [load] load() called — id=XXXXXX  ✓
//   play#2 expected=XXXXXX  →  [load] load() called — id=XXXXXX  ✓  (same card, second tap)
//   play#3 expected=YYYYYY  →  [load] load() called — id=YYYYYY  ✓
//   play#4 expected=XXXXXX  →  [load] load() called — id=XXXXXX  ✓
//
// BUG signature (wrong video played):
//   play#2 expected=XXXXXX  →  [load] load() called — id=YYYYYY  ← MISMATCH = bug
//
// Additional log patterns to note per play:
//   ✓ readyToPlay in \d+ ms   — player reached ready state
//   ✓ path [A|B|C] won        — winning fetch path
//   · exhaustiveRetry          — RED FLAG: all race paths failed
//   · ERROR / error / failed   — RED FLAG: unexpected failure
//
// LEGITIMATE skip:
//   - Network unavailable / home feed empty (< 2 non-Shorts cards)
// BUG skip (must investigate):
//   - player.titleLabel never appeared within 30 s

// MARK: -

final class WrongVideoRegressionUITests: XCTestCase {

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
        app.launch()
    }

    override func tearDownWithError() throws {
        app?.terminate()
        app = nil
    }

    // MARK: - Helpers

    /// Returns all non-Shorts video cards currently accessible in the UI tree.
    /// Short cards carry `accessibilityValue == "short"` (set by VideoGridSection).
    private func nonShortsCardQuery() -> XCUIElementQuery {
        app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'video.card.' AND value != 'short'")
        )
    }

    /// Dismisses the full-screen player via its back button, then closes the
    /// mini-player if it appears. Waits for `home.chipBar` to confirm the feed
    /// is fully visible before returning.
    private func dismissPlayerAndReturnToHome() {
        let backBtn = app.buttons["player.backButton"].firstMatch
        if backBtn.waitForExistence(timeout: 5) {
            backBtn.tap()
        }
        let miniClose = app.buttons["miniPlayer.closeButton"].firstMatch
        if miniClose.waitForExistence(timeout: 3) {
            miniClose.tap()
        }
        _ = app.scrollViews["home.chipBar"].waitForExistence(timeout: 5)
    }

    /// Finds `video.card.<videoId>` in the current feed, taps it, and waits for
    /// `player.titleLabel` to appear.
    ///
    /// Prints `[wrongvideo] play#N expected=<videoId>` immediately before the tap
    /// so post-run log grep can pair it against the app's `[load] load() called — id=`
    /// line.
    ///
    /// - Returns: the player title label text on success.
    /// - Throws: `XCTSkip` if the card is not found, `XCTFail` if the player
    ///   times out.
    @discardableResult
    private func tapAndPlay(videoId: String, playNumber: Int) throws -> String {
        let card = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'video.card.\(videoId)'"))
            .firstMatch
        guard card.waitForExistence(timeout: 8) else {
            try captureAndSkip(
                "play#\(playNumber): card video.card.\(videoId) not found in feed",
                in: app
            )
        }

        print("[wrongvideo] play#\(playNumber) expected=\(videoId)")
        let tapStart = Date()
        card.tap()

        let titleLabel = app.staticTexts["player.titleLabel"].firstMatch
        guard titleLabel.waitForExistence(timeout: 30) else {
            captureState("timeout-play\(playNumber)-\(videoId)", in: app)
            XCTFail("play#\(playNumber) [\(videoId)]: player.titleLabel never appeared within 30 s")
            return ""
        }

        let ttpMs = Int(Date().timeIntervalSince(tapStart) * 1000)
        let title = titleLabel.label
        print("[wrongvideo] play#\(playNumber) opened — title='\(title)'")
        print("[wrongvideo] play#\(playNumber) TTP=\(ttpMs)ms  tap→titleLabel  videoId=\(videoId)")

        // Dwell so [load], readyToPlay, quality-ramp, and path-won log lines all land.
        Thread.sleep(forTimeInterval: 3.0)
        return title
    }

    // MARK: - Test

    /// Plays two Home feed videos through four sequential load/dismiss cycles.
    ///
    /// The cycle order is designed to maximise the chance of triggering an
    /// index-staleness or identity-confusion bug:
    ///   play#1 (video A) → back → play#2 (video A again) → back →
    ///   play#3 (video C, 3rd non-Short) → back → play#4 (video A one more time)
    func testCorrectVideoLoadedOnRepeatedHomeCardTaps() throws {

        // ── 1. Navigate to Home and wait for at least 2 non-Shorts cards ────
        UITestHelpers.tapTab(named: "Home", in: app)
        guard UITestHelpers.waitForVideoCards(in: app, timeout: 25) != nil else {
            try captureAndSkip("Home feed did not load — network or sign-in issue.", in: app)
        }

        // Collect all visible non-Shorts card identifiers and find two DISTINCT video IDs.
        // The same card can appear multiple times in the accessibility tree (e.g. featured
        // row + main grid), so positional indexing is unreliable — we deduplicate.
        let threeCardsExpectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "count >= 3"),
            object: nonShortsCardQuery()
        )
        _ = XCTWaiter().wait(for: [threeCardsExpectation], timeout: 15)

        let allCards = nonShortsCardQuery()
        var seenIDs: [String] = []
        for i in 0..<min(allCards.count, 30) {
            let rawId = allCards.element(boundBy: i).identifier
            let vid = rawId.replacingOccurrences(of: "video.card.", with: "")
            guard !vid.isEmpty, !seenIDs.contains(vid) else { continue }
            seenIDs.append(vid)
            if seenIDs.count == 3 { break }
        }

        guard seenIDs.count >= 3 else {
            try captureAndSkip(
                "Home feed has fewer than 3 distinct non-Shorts video IDs (found \(seenIDs)) — cannot run scenario.",
                in: app
            )
        }

        let videoId1 = seenIDs[0]
        let videoId2 = seenIDs[2]
        print("[wrongvideo] setup: first=\(videoId1) third=\(videoId2)")

        // ── Play #1: first video ─────────────────────────────────────────────
        try tapAndPlay(videoId: videoId1, playNumber: 1)
        dismissPlayerAndReturnToHome()

        // ── Play #2: same first video again ──────────────────────────────────
        // Key regression moment: re-tapping the same card after a dismiss.
        try tapAndPlay(videoId: videoId1, playNumber: 2)
        dismissPlayerAndReturnToHome()

        // ── Play #3: third distinct non-Short video ────────────────────────────
        try tapAndPlay(videoId: videoId2, playNumber: 3)
        dismissPlayerAndReturnToHome()

        // ── Play #4: first video one final time ──────────────────────────────
        try tapAndPlay(videoId: videoId1, playNumber: 4)

        // Final state assertions.
        XCTAssertEqual(app.state, .runningForeground,
                       "App must remain in foreground throughout all play/dismiss cycles")
        UITestHelpers.assertNoPlayerErrorBanner(in: app)
    }
}
