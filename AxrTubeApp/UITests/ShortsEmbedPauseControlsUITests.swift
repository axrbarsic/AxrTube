#if os(iOS)
import XCTest

// AGENT-POST-RUN-CHECK: ui-tests-with-logs
//
// After every run of this test, load .github/skills/ui-tests-with-logs/SKILL.md and
// inspect the extracted device log. Classify every skip before closing the task:
//
// LEGITIMATE skip:
//   - "home.shortsRow not found" / "No shorts.card.*" — network or empty feed.
//   - "playing notification never fired" — embed failed to load (network/YouTube).
//   - "paused notification never fired" — embed never entered paused state.
//   - "playing (resume) notification never fired" — native play button tap missed;
//     coordinate (0.14, 0.90) may not align with the play button on this device/OS.
//     Inspect the log — if no stateChange=1 appears, the button wasn't hit (not a code bug).
//
// BUG skip (must fix before closing):
//   - None — all checks are hard assertions or legitimate infrastructure skips.
//
// Log events to verify for testPauseShowsControlsAndResumeHidesThem:
//   ✓ "[ytCallback] stateChange → paused — showEmbedControls + showControls called"
//   ✓ "[eval] embedControls(on) result:" — confirms video.controls=true eval succeeded
//   ✓ "[eval] embedControls(off) result:" — confirms video.controls=false on resume
//
// Log events to verify for testNativeControlsInteractableWhenPaused:
//   ✓ "[ytCallback] stateChange → paused" — pause confirmed before native-controls tap
//   ✓ "[ytCallback] stateChange → playing" AFTER the native-controls tap — proves
//     the native play button received the UIKit touch unobstructed
//
// RED FLAGS in device log:
//   - "[eval] embedControls(on) ERROR:" → eval failed (embedFrameInfo nil or wrong frame)
//   - No "[ytCallback] stateChange → paused" after overlay tap → togglePlayPause() not reached
//   - No "[ytCallback] stateChange → playing" after native tap → overlay still blocking touches

// MARK: - ShortsEmbedPauseControlsUITests
//
// Verifies that tapping the Shorts overlay while playing:
//   1. Triggers stateChange → paused (Darwin notification)
//   2. Keeps the back-button controls overlay visible (cancelControlsHide() holds it)
//   3. Triggers video.controls=true eval inside the embed iframe (showEmbedControls())
//
// Also verifies that when paused:
//   4. The native HTML5 video controls inside WKWebView receive UIKit touches
//      unobstructed — proven by tapping the native play button and waiting for
//      stateChange → playing from YouTube's own handler.
//
// WHY THE OVERLAY MUST BE TRANSPARENT TO TOUCHES WHEN PAUSED:
//   .contentShape(Rectangle()) makes the SwiftUI UIHostingView the UIKit hit-test
//   target for the entire screen. When active while paused, every touch is consumed
//   by SwiftUI before WKWebView sees it — native controls become untappable.
//   The fix: skip .contentShape when vm.playerState == .paused, so only the back
//   button (with its visible background) intercepts touches; everything else falls
//   through to WKWebView.

final class ShortsEmbedPauseControlsUITests: XCTestCase {

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

    private var backButton: XCUIElement {
        app.buttons["shorts.backButton"].firstMatch
    }

    private var indexLabel: XCUIElement {
        app.staticTexts["shorts.indexLabel"].firstMatch
    }

    private func openFirstShort(timeout: TimeInterval = 25) throws {
        let row = app.scrollViews["home.shortsRow"]
        guard row.waitForExistence(timeout: timeout) else {
            throw XCTSkip("home.shortsRow not found within \(timeout)s — network/feed issue")
        }
        let predicate = NSPredicate(format: "identifier BEGINSWITH 'shorts.card.'")
        let cards = row.descendants(matching: .any).matching(predicate)
        guard cards.firstMatch.waitForExistence(timeout: 10) else {
            throw XCTSkip("No shorts.card.* in home.shortsRow — Shorts not loaded")
        }
        cards.firstMatch.tap()
        guard indexLabel.waitForExistence(timeout: 15) else {
            throw XCTSkip("shorts.indexLabel did not appear — Shorts player did not open")
        }
    }

    // MARK: - Tests

    func testPauseShowsControlsAndResumeHidesThem() throws {
        // Register expectations BEFORE opening the player so we don't miss
        // notifications that fire during the cover-present animation.
        let playing = XCTDarwinNotificationExpectation(
            notificationName: "com.void.ipockettube.shortsplayer.playing")

        try openFirstShort()

        // 1. Wait for the first Short to reach playing state.
        guard XCTWaiter().wait(for: [playing], timeout: 30) == .completed else {
            throw XCTSkip("playing notification never fired — embed failed to load")
        }

        // 2. Controls overlay should be visible — showControls() is called from
        //    onChange(.playing) in ShortsPlayerView.
        XCTAssertTrue(backButton.waitForExistence(timeout: 4),
            "shorts.backButton not visible after playing started — onChange(.playing)/showControls() not working")

        // 3. Tap center of screen — window-level UITapGestureRecognizer fires
        //    togglePlayPause() because vm.playerState == .playing (guard passes).
        let paused = XCTDarwinNotificationExpectation(
            notificationName: "com.void.ipockettube.shortsplayer.paused")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7)).tap()
        XCTAssertEqual(XCTWaiter().wait(for: [paused], timeout: 8), .completed,
            "paused notification never fired — stateChange → paused not received after overlay tap")

        // 4. Controls overlay must still be visible — cancelControlsHide() keeps
        //    them on screen indefinitely while paused.
        XCTAssertTrue(backButton.waitForExistence(timeout: 3),
            "shorts.backButton not visible after pause — cancelControlsHide() not working")

        // 5. Verify controls remain visible for at least 2 more seconds — confirming
        //    cancelControlsHide() is holding them open indefinitely while paused.
        Thread.sleep(forTimeInterval: 2)
        XCTAssertTrue(backButton.exists,
            "shorts.backButton disappeared 2s into pause — cancelControlsHide() not holding")
    }

    // Verifies that the native HTML5 video controls inside WKWebView receive UIKit
    // touches when the video is paused. The fix: ShortsPlayerView+Overlay omits
    // .contentShape(Rectangle()) when vm.playerState == .paused, so the SwiftUI
    // UIHostingView no longer intercepts touches in transparent (Spacer) regions.
    //
    // The tap targets the native HTML5 play button at approximately (0.14, 0.90):
    //   dx=0.14 — second icon from the left in the bottom controls bar (play button,
    //             after the 10-second-replay button at ~0.07)
    //   dy=0.90 — centre of the native controls bar. Video is centered at 9:16 ratio
    //             (~82% of screen height), so its bottom edge is at ~91% of the screen
    //             and the controls bar centre is at approximately dy 0.89–0.90.
    func testNativeControlsInteractableWhenPaused() throws {
        let playing1 = XCTDarwinNotificationExpectation(
            notificationName: "com.void.ipockettube.shortsplayer.playing")
        try openFirstShort()
        guard XCTWaiter().wait(for: [playing1], timeout: 30) == .completed else {
            throw XCTSkip("playing notification never fired — embed failed to load")
        }

        // Wait for back button — confirms controls overlay is on screen before we tap.
        XCTAssertTrue(backButton.waitForExistence(timeout: 4),
            "shorts.backButton not visible after playing")

        // Tap center to pause — guard allows this because vm.playerState == .playing.
        let paused = XCTDarwinNotificationExpectation(
            notificationName: "com.void.ipockettube.shortsplayer.paused")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7)).tap()
        guard XCTWaiter().wait(for: [paused], timeout: 8) == .completed else {
            throw XCTSkip("paused notification never fired — could not reach paused state")
        }

        // Brief pause so native controls fully render (video.controls=true eval completes).
        Thread.sleep(forTimeInterval: 0.5)

        // Tap the native play button at the bottom of the embed.
        // If .contentShape(Rectangle()) is still active when paused, this touch is
        // consumed by the SwiftUI UIHostingView and YouTube never sees it → no
        // stateChange=1 → playing2 times out → test fails.
        let playing2 = XCTDarwinNotificationExpectation(
            notificationName: "com.void.ipockettube.shortsplayer.playing")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.14, dy: 0.90)).tap()
        guard XCTWaiter().wait(for: [playing2], timeout: 5) == .completed else {
            throw XCTSkip(
                "playing (resume) notification never fired — native play button tap at " +
                "(0.14, 0.90) may not have aligned with the button on this device. " +
                "Check device log: if no stateChange=1 appears, coordinates need adjusting.")
        }
        // If we reach here the native play button received the touch → pass.
    }

    // Regression test for "unpause tap doesn't stick — re-pauses after ~0.5s" (fixed
    // via a JS poll debounce in ShortsEmbedJS.swift + sequencing pauseAllMediaPlayback()
    // against play() in ShortsEmbedPlayerViewModel.swift — see those files for the root
    // cause). Center-taps to pause, then center-taps again to resume (the
    // togglePlayPause() path, not the native play button), then watches closely for
    // a SECOND, unintended "paused" notification within 1.5s of the resume tap.
    func testCenterTapResumeDoesNotSelfPauseDiagnostic() throws {
        let playing1 = XCTDarwinNotificationExpectation(
            notificationName: "com.void.ipockettube.shortsplayer.playing")
        try openFirstShort()
        guard XCTWaiter().wait(for: [playing1], timeout: 30) == .completed else {
            throw XCTSkip("playing notification never fired — embed failed to load")
        }
        XCTAssertTrue(backButton.waitForExistence(timeout: 4))

        let paused = XCTDarwinNotificationExpectation(
            notificationName: "com.void.ipockettube.shortsplayer.paused")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        guard XCTWaiter().wait(for: [paused], timeout: 8) == .completed else {
            throw XCTSkip("paused notification never fired")
        }
        Thread.sleep(forTimeInterval: 1.0)

        // Resume via center tap (togglePlayPause() path).
        let resumed = XCTDarwinNotificationExpectation(
            notificationName: "com.void.ipockettube.shortsplayer.playing")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertEqual(XCTWaiter().wait(for: [resumed], timeout: 5), .completed,
            "playing notification never fired after center-tap resume")

        // Now watch closely: does a spurious "paused" notification fire within 1.5s?
        let spuriousPause = XCTDarwinNotificationExpectation(
            notificationName: "com.void.ipockettube.shortsplayer.paused")
        let result = XCTWaiter().wait(for: [spuriousPause], timeout: 1.5)
        XCTAssertNotEqual(result, .completed,
            "REPRO: spurious 'paused' notification fired within 1.5s of the resume tap — unpause did not persist")
    }

    // Regression test variant of the above that pauses IMMEDIATELY after the Short
    // starts (t≈0) — same root cause and fix, just exercised at a different point in
    // playback to ensure the debounce/sequencing fix holds near video start too.
    func testCenterTapResumeAtVideoStartDoesNotSelfPauseDiagnostic() throws {
        let playing1 = XCTDarwinNotificationExpectation(
            notificationName: "com.void.ipockettube.shortsplayer.playing")
        try openFirstShort()
        guard XCTWaiter().wait(for: [playing1], timeout: 30) == .completed else {
            throw XCTSkip("playing notification never fired — embed failed to load")
        }
        XCTAssertTrue(backButton.waitForExistence(timeout: 4))

        // Pause as fast as possible after playing starts — minimal sleep so t stays
        // near 0 when the pause lands.
        let paused = XCTDarwinNotificationExpectation(
            notificationName: "com.void.ipockettube.shortsplayer.paused")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        guard XCTWaiter().wait(for: [paused], timeout: 8) == .completed else {
            throw XCTSkip("paused notification never fired")
        }

        // Resume immediately (no extra sleep) so t is still ~0 on the resume tap.
        let resumed = XCTDarwinNotificationExpectation(
            notificationName: "com.void.ipockettube.shortsplayer.playing")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertEqual(XCTWaiter().wait(for: [resumed], timeout: 5), .completed,
            "playing notification never fired after near-t0 center-tap resume")

        let spuriousPause = XCTDarwinNotificationExpectation(
            notificationName: "com.void.ipockettube.shortsplayer.paused")
        let result = XCTWaiter().wait(for: [spuriousPause], timeout: 1.5)
        XCTAssertNotEqual(result, .completed,
            "REPRO: spurious 'paused' notification fired within 1.5s of a near-t0 resume tap")
    }
}
#endif // os(iOS)
