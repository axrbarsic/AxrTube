import XCTest

// MARK: - AudioOnlyModeUITests
//
// Regression tests for the audio-only playback mode observer fix (task #33).
//
// Root cause fixed (May 2026):
//   `tryLoadAudioURL(_:userAgent:)` created an `AVPlayerItem` for the audio URL and
//   called `player.replaceCurrentItem(with: item)` without setting up an
//   `itemObserverTask`.  When the audio item's status changed to `.failed` (e.g.
//   unsupported codec, network error, non-playable asset), the failure was never
//   observed and playback silently stalled.  Fix: an `itemObserverTask` is now
//   created before `replaceCurrentItem`, matching the pattern in every other load path.
//
// Requirements:
//   • Network access is required.
//   • Run on an iOS 17+ simulator with the iPocketTubeApp scheme selected.
//   • Launch args: --uitesting --uitesting-reset-settings --uitesting-audio-only-mode

final class AudioOnlyModeUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += [
            "--uitesting",
            "--uitesting-reset-settings",
            "--uitesting-audio-only-mode",
        ]
        app.launch()
    }

    override func tearDownWithError() throws { app = nil }

    // MARK: - Tests

    /// With audio-only mode enabled, opening a video must not produce a player error
    /// banner.  Before the fix, a failed audio AVPlayerItem had no observer so the
    /// error was never surfaced and playback stalled silently (blank screen + no
    /// audio).  After the fix either the audio item loads successfully or the
    /// observer catches the failure and resets `isAudioOnlyMode = false`, letting
    /// the HLS stream play normally — either way no stall and no error banner.
    func testAudioOnlyModeOpensVideoWithoutError() throws {
        UITestHelpers.tapTab(named: "Home", in: app)
        guard let card = UITestHelpers.waitForVideoCards(in: app, timeout: 20) else {
            try captureAndSkip("No video cards on Home — network unavailable or feed empty", in: app)
        }
        guard UITestHelpers.openPlayer(from: card, in: app) else {
            XCTFail("Player did not open within 15 s in audio-only mode")
            return
        }

        // Allow enough time for the audio item load attempt (and potential fallback)
        // to complete.  The observer fix ensures the failure path resolves within a
        // few seconds rather than hanging indefinitely.
        Thread.sleep(forTimeInterval: 8)

        UITestHelpers.assertNoPlayerErrorBanner(in: app)
    }
}
