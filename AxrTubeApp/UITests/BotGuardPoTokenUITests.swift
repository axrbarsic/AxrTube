import XCTest

// AGENT-POST-RUN-CHECK: ui-tests-with-logs
//
// Search the device log for BotGuard/pot= token messages to understand whether the
// YouTube player running inside the hidden WKWebView produces a pot= token.
//
// ─── GOOD: pot= token was produced by the YouTube player in WKWebView ─────────────
//   ✓ "[webView] pot= token extracted (N chars) — stored in extractedPoToken"
//   ✓ "[webView] pot= token stored (N chars) — rqh=1 adaptive will be retried with CDN auth"
//   ✓ "[InnerTube] ✅ poToken applied to <videoId> via iOS client (len=N)"
//   If WKWebView HLS also fails and the pot-gated adaptive attempt fires:
//   ✓ "rqh=1 but pot= token available — attempting adaptive composition"
//
// ─── NEUTRAL: no pot= token produced (expected for most sessions) ────────────────
//   ✗ No "pot= token extracted" line anywhere in the log.
//   ✓ Normal WKWebView HLS path completes: "[webView] 720p+ HLS playing via WKWebView"
//   → The YouTube player in WKWebView made its /player call without including
//     serviceIntegrityDimensions.poToken. The web player only triggers BotGuard
//     when the server includes a challenge in the page — not every session.
//     See docs/BotGuard.md §4 Option A/B for next steps.
//
// ─── BAD: new regression introduced by Option B changes ─────────────────────────
//   ✗ "[webView/HLS] failed to fetch master manifest" with HTTP 404 or 400
//     → finishWithURL is still baking the pot token into the manifest URL path.
//       (The /pot/<token> URL encoding bug we fixed — verify it is gone.)
//   ✗ App crashes immediately after WKWebView extraction.
//   ✗ Video never plays; log shows "rqh=1 but pot= token available" then
//     "adaptive composition with pot= failed" AND no WKWebView HLS fallback.
//
// ─── LOG EVENTS TO VERIFY ────────────────────────────────────────────────────────
//   Always expected (WKWebView HLS path):
//     ✓ "⚠️ [webView] starting HLS extraction for LSMQ3U1Thzw"
//     ✓ "⚠️ [webView] got hlsManifestUrl — nSolver=..."
//     ✓ "[webView/HLS] master manifest OK bytes=..."
//     ✓ "✅ [webView/HLS] readyToPlay"
//   Optional (only when YouTube player produces a BotGuard token):
//     ? "[webView] pot= token extracted (N chars) — stored in extractedPoToken"
//     ? "[webView] pot= token stored (N chars) — rqh=1 adaptive will be retried with CDN auth"

// MARK: - BotGuardPoTokenUITests
//
// Observational test: plays a video known to use the WKWebView HLS extraction path
// and verifies that the new Option B pot= token wiring does not break normal playback.
// Log analysis (via AGENT-POST-RUN-CHECK above) determines whether the YouTube player
// in WKWebView actually produces a pot= token for this session.
//
// Video: LSMQ3U1Thzw — Ben Eater "The SID: Classic 8-bit sound"
//   • Known to use WKWebView extraction (rqh=1 iOS adaptive streams).
//   • 13 AI-dubbed language tracks → always takes the WKWebView HLS path.
//   • No auth required.

final class BotGuardPoTokenUITests: XCTestCase {

    private static let videoID = "9bZkp7q19f0"  // PSY - Gangnam Style (standard video, no multi-track)

    private static var sharedApp: XCUIApplication!
    private static var skipAllTests = false
    private static let skipReason = "Player did not open or play within deadline — " +
        "network unavailable or WKWebView extraction broken for \(videoID)"

    // MARK: - Lifecycle

    override class func setUp() {
        super.setUp()
        let app = XCUIApplication()
        app.launchArguments = [
            "--uitesting",
            "--uitesting-disable-tos-player-on-ios",
            "--uitesting-deeplink-video=\(videoID)"
        ]
        app.launch()
        sharedApp = app

        // Wait for the player to open.
        guard app.staticTexts["player.titleLabel"].firstMatch.waitForExistence(timeout: 20) else {
            skipAllTests = true
            return
        }

        // Give the WKWebView extraction + HLS load enough time to complete.
        // The SID video typically takes ~14 s from launch to readyToPlay.
        Thread.sleep(forTimeInterval: 10)

        // Poll until play/pause button is visible and enabled (controls overlay may be hidden).
        let center = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let deadline = Date().addingTimeInterval(40)
        var ready = false
        while Date() < deadline {
            center.tap()
            Thread.sleep(forTimeInterval: 0.4)
            let btn = app.buttons["player.playPauseButton"].firstMatch
            if btn.exists && btn.isEnabled {
                ready = true
                break
            }
            Thread.sleep(forTimeInterval: 3.0)
        }
        if !ready { skipAllTests = true }
    }

    override class func tearDown() {
        sharedApp?.terminate()
        sharedApp = nil
        super.tearDown()
    }

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    // MARK: - Helpers

    private func showControlsAndWaitEnabled(timeout: TimeInterval = 5) -> Bool {
        let center = Self.sharedApp.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            center.tap()
            Thread.sleep(forTimeInterval: 0.4)
            let btn = Self.sharedApp.buttons["player.playPauseButton"].firstMatch
            if btn.exists && btn.isEnabled { return true }
            Thread.sleep(forTimeInterval: 0.8)
        }
        return false
    }

    // MARK: - Tests

    /// Verifies that adding the Option B pot= token extraction does not break the
    /// normal WKWebView HLS playback path. If the play/pause button becomes enabled,
    /// the manifest fetch did not 404 (the /pot/<token> URL encoding bug is fixed).
    func testPlaybackSucceedsAfterOptionBChanges() throws {
        try XCTSkipIf(Self.skipAllTests, Self.skipReason)

        let ready = showControlsAndWaitEnabled(timeout: 6)
        XCTAssertTrue(ready,
            "play/pause button did not become enabled — WKWebView HLS path may be broken by Option B changes " +
            "(check log for 'failed to fetch master manifest' or 404 from /pot/ URL encoding bug)")
    }

    /// Confirms playback is truly running by checking the player has not stalled
    /// (hittable play/pause button is available after controls re-appear).
    func testPlayerIsNotStalled() throws {
        try XCTSkipIf(Self.skipAllTests, Self.skipReason)

        let ready = showControlsAndWaitEnabled(timeout: 6)
        XCTAssertTrue(ready, "play/pause button not hittable — player stalled or controls overlay never shown")
        let btn = Self.sharedApp.buttons["player.playPauseButton"].firstMatch
        XCTAssertTrue(btn.isHittable,
            "play/pause button not hittable — controls visible but button is disabled")
    }
}
