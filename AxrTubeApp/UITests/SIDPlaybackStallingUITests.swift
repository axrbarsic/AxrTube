import XCTest

// AGENT-POST-RUN-CHECK: ui-tests-with-logs
//
// After this test, load .github/skills/ui-tests-with-logs/SKILL.md and extract the device
// log. This test targets bug #193 — video stalling every 1-2 minutes.
//
// ─── GOOD: 5-minute playback with no stall ───────────────────────────────────────
//   ✓ "✅ [webView/HLS] readyToPlay" — video loaded successfully
//   ✓ [stats] snapshot lines appear at regular ~30 s intervals throughout the test
//   ✓ No "[rateObserver] player.rate→0 while isPlaying=true" line in the log
//   ✓ All 10 per-minute poll checks pass (play/pause button remains hittable)
//   ✓ "player.errorBanner" does NOT appear in the accessibility tree at any checkpoint
//
// ─── BAD: video stalled (bug #193 reproduced) ────────────────────────────────────
//   ✗ "[rateObserver] player.rate→0 while isPlaying=true" — AVPlayer externally paused
//     → Cause: AVPlayerItemPlaybackStalled, WKWebView HLS URL expiry (expire= param),
//       or AVAudioSession interruption not auto-resumed. See tasks.md #193.
//   ✗ "[stats] snapshot" gaps > 60 s — stats ticker stopped (player froze)
//   ✗ Test assertion fails at one of the 30-second checkpoints
//   ✗ "player.errorBanner" appears in the UI
//
// ─── LOG EVENTS TO VERIFY ────────────────────────────────────────────────────────
//   Always expected:
//     ✓ "⚠️ [webView] starting HLS extraction for LSMQ3U1Thzw"
//     ✓ "⚠️ [webView] got hlsManifestUrl — nSolver=..."
//     ✓ "[webView/HLS] master manifest OK bytes=..."
//     ✓ "✅ [webView/HLS] readyToPlay"
//   Stall signature (bug #193):
//     ✗ "[rateObserver] player.rate→0 while isPlaying=true — syncing isPlaying=false"
//       followed by no "[loadAsync]" or "[resume]" recovery within ~10 s
//   HLS URL expiry signature:
//     ✗ "[webView/HLS] failed to fetch" or HTTP 403/404 in the log around the stall time
//   Stats progress check — confirm playback advanced:
//     → Run: grep -n "\[stats\] snapshot" "$APP_LOG"
//       Each line should show a different res/codec — gaps > 60 s indicate freeze.
//
// ─── STALL DIAGNOSIS ─────────────────────────────────────────────────────────────
//   If "[rateObserver] player.rate→0" fires:
//     1. Check for AVAudioSession interruption (look for "interruption" in log)
//     2. Check for HLS segment 403/404 near the timestamp (expire= param expired)
//     3. Check for "AVPlayerItemPlaybackStalled" notification — not currently logged;
//        add playerLog.notice("[stall] AVPlayerItemPlaybackStalled fired") to
//        PlaybackViewModel+Loading.swift setupItemObservers if not present.
//   If rate stays non-zero but video freezes:
//     → timeControlStatus = waitingToPlayAtSpecifiedRate (buffering stall)
//     → Check "numberOfStalls" in [stats] snapshot lines

// MARK: - SIDPlaybackStallingUITests
//
// Sustained 5-minute playback test for bug #193 — "video stalls every few minutes".
//
// Opens the SID video (LSMQ3U1Thzw — Ben Eater "The SID: Classic 8-bit sound") via
// deep-link, waits for readyToPlay, then polls every 30 seconds for 5 minutes to
// confirm the player remains active and no error banner has appeared.
//
// The SID video is the canonical regression vehicle because:
//   • Uses WKWebView HLS extraction path (rqh=1 adaptive URLs on simulator)
//   • ~20-minute duration — long enough to observe periodic stalls
//   • No auth required
//   • Reliably produces "readyToPlay" on any simulator with network access
//
// Requirements:
//   • Network access is required.
//   • Allow at least 8 minutes total for the test (setup + 5 min play + teardown).
//   • Xcode default 10-minute test timeout is sufficient. If your CI has a shorter
//     per-test limit, set `executionTimeAllowance` below.

final class SIDPlaybackStallingUITests: XCTestCase {

    /// Ben Eater "The SID: Classic 8-bit sound" — ~20-minute video, WKWebView HLS path.
    private static let videoID = "LSMQ3U1Thzw"

    /// Total playback monitoring duration in seconds (5 minutes).
    private static let playDuration: TimeInterval = 5 * 60

    /// Interval between stall checks in seconds.
    private static let checkInterval: TimeInterval = 30

    private var app: XCUIApplication!
    private var skipReason: String?

    // MARK: - Lifecycle

    override func setUpWithError() throws {
        continueAfterFailure = false
        // Allow 8 minutes: ~1 min startup + 5 min play + 2 min margin.
        executionTimeAllowance = 480

        app = XCUIApplication()
        app.launchArguments = [
            "--uitesting",
            "--uitesting-disable-tos-player-on-ios",
            "--uitesting-deeplink-video=\(Self.videoID)"
        ]
        app.launch()
    }

    override func tearDownWithError() throws {
        app?.terminate()
        app = nil
    }

    // MARK: - Test

    /// Plays the SID video for 5 minutes and asserts the player never stalls.
    ///
    /// Each 30-second checkpoint verifies:
    ///   1. No `player.errorBanner` is visible in the UI.
    ///   2. The play/pause button is hittable (controls overlay can be shown and button
    ///      is enabled — stalled players leave the button disabled or non-hittable).
    func testNoStallingDuringFiveMinutePlayback() throws {
        // ── Step 1: Wait for the player title to confirm the deep-link opened. ──
        guard app.staticTexts["player.titleLabel"].firstMatch.waitForExistence(timeout: 20) else {
            throw XCTSkip("Player title did not appear within 20 s — " +
                          "network unavailable or deep-link broken for \(Self.videoID)")
        }

        // ── Step 2: Poll until readyToPlay (WKWebView HLS extraction can take ~20 s). ──
        // Tap the screen periodically so controls stay visible; once isLoading=false
        // the freshly-shown play/pause button will be enabled.
        let center = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let readyDeadline = Date().addingTimeInterval(50)
        var readyToPlay = false
        while Date() < readyDeadline {
            center.tap()
            Thread.sleep(forTimeInterval: 0.5)
            let btn = app.buttons["player.playPauseButton"].firstMatch
            if btn.exists && btn.isEnabled {
                readyToPlay = true
                break
            }
            Thread.sleep(forTimeInterval: 3.0)
        }

        guard readyToPlay else {
            throw XCTSkip("Player did not reach readyToPlay within 50 s — " +
                          "network unavailable or WKWebView HLS extraction failed for \(Self.videoID)")
        }

        // ── Step 3: Let auto-hide fire so controls disappear, simulating real usage. ──
        Thread.sleep(forTimeInterval: 5)

        // ── Step 4: Poll every 30 seconds for 5 minutes. ──
        let numberOfChecks = Int(Self.playDuration / Self.checkInterval)
        for check in 1...numberOfChecks {
            let elapsed = check * Int(Self.checkInterval)
            Thread.sleep(forTimeInterval: Self.checkInterval)

            // Assert no error banner is shown without tapping (passive check).
            let errorBanner = app.staticTexts["player.errorBanner"].firstMatch
            let ipBlockBanner = app.staticTexts["player.ipBlockBanner"].firstMatch
            XCTAssertFalse(
                errorBanner.exists,
                "player.errorBanner appeared at \(elapsed)s — video may have stalled or returned an error"
            )
            XCTAssertFalse(
                ipBlockBanner.exists,
                "player.ipBlockBanner appeared at \(elapsed)s — IP-block error during sustained playback"
            )

            // Tap to show controls then assert play/pause is enabled (active playback indicator).
            center.tap()
            Thread.sleep(forTimeInterval: 0.5)

            let playPause = app.buttons["player.playPauseButton"].firstMatch
            XCTAssertTrue(
                playPause.exists && playPause.isEnabled,
                "play/pause button not enabled at \(elapsed)s checkpoint \(check)/\(numberOfChecks) — " +
                "player may have stalled (bug #193). Check device log for " +
                "'[rateObserver] player.rate→0' or HLS segment 403/404 near this timestamp."
            )

            // Let controls auto-hide before the next check.
            Thread.sleep(forTimeInterval: 4.5)
        }
    }
}
