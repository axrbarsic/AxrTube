#if os(iOS)
import XCTest

// AGENT-POST-RUN-CHECK: ui-tests-with-logs
//
// After every run of tests in this file, load
// .github/skills/ui-tests-with-logs/SKILL.md and inspect the extracted device log.
// Classify every skip before closing the task:
//
// LEGITIMATE skip:
//   - "No video cards found" / "No non-short video card found" — home feed network
//     unavailable or Google auth cookie expired. Device log should show
//     "[Browse] home feed empty" or "Multilogin HTTP 403 INVALID_TOKENS".
//   - "onPlayerReady never fired" — IFrame embed failed to load (network/YouTube
//     availability), unrelated to the TOS player code path under test. Device log
//     should show "[ytCallback] ❌ player error" or no "ready" notice.
//
// BUG skip (must fix before closing):
//   - Any skip reached AFTER tosPlayer.stateLabel appeared — by that point the
//     WKWebView loaded and the only remaining work is mini-player state transitions,
//     so a skip there means that flow broke.
//
// Log events to verify:
//   ✓ "[TOSPlayerStateStore] play — presentation set to .fullScreen"
//   ✓ "[TOSPlayerView] onDisappear — minimizing to mini-player, audio continues"
//   ✓ "[TOSPlayerStateStore] minimize — presentation set to .miniPlayer"
//   ✓ "[TOSPlayerStateStore] stop — presentation set to .hidden, vm released"   (stop test only)
//
// RED FLAGS in device log:
//   - "[TOSPlayerView] onDisappear — fully stopped" right after back-button tap →
//     tosState.presentation was .hidden instead of .miniPlayer — minimize() failed
//   - "vm is nil" crash or "tosState.vm! unexpectedly found nil" →
//     TOSPlayerStateStore.vm was released before TOSPlayerView appeared

// MARK: - TOSPlayerIOSUITests
//
// Smoke tests for the iOS IFrame (TOS-compliant) player.
//
// What the tests verify:
//   testTOSPlayerIOSSmoke:
//     1. Tapping a home video card opens the TOS player (tosPlayer.stateLabel visible).
//     2. The IFrame player starts playing within 30 s (Darwin notification + AX state).
//     3. Tapping the back button → stateLabel disappears (cover dismissed).
//     4. TOSMiniPlayerView appears at the bottom (mini-player bar visible, audio continues).
//
//   testTOSPlayerIOSStopsOnClose:
//     1. Opens TOS player, verifies playing.
//     2. Taps back button → mini-player bar appears.
//     3. Taps the ✕ (close) button → mini-player bar disappears (fully stopped).
//
// Preconditions:
//   - useTOSPlayerOnIOS is forced true via --uitesting-enable-tos-player-on-ios.
//   - --uitesting-reset-settings ensures settings don't bleed between runs.
//   - --uitesting-disable-sponsorblock prevents SponsorBlock skips from interfering.
//
// Darwin notifications:
//   CFNotificationCenterPostNotification is a CoreFoundation API available on iOS.
//   The same notification names emitted by TOSPlayerViewModel fire here; XCUITest
//   captures them via XCTDarwinNotificationExpectation exactly as in TOSPlayerUITests.

final class TOSPlayerIOSUITests: XCTestCase {

    private var app: XCUIApplication!

    // MARK: - Lifecycle

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        app?.terminate()
        app = nil
    }

    // MARK: - Launch helpers

    /// Launches a fresh XCUIApplication with --uitesting plus given extra arguments.
    /// One launch per test — see TOSPlayerUITests for why mid-test terminate+relaunch
    /// causes a deterministic auth-state race.
    private func launchApp(extraArguments: [String] = []) {
        app = XCUIApplication()
        app.launchArguments = [
            "--uitesting",
            "--uitesting-reset-settings",
            "--uitesting-enable-tos-player-on-ios",
            "--uitesting-disable-sponsorblock"
        ] + extraArguments
        app.launch()
    }

    // MARK: - Helpers

    /// Waits for at least one video.card.* element. Returns `nil` and skips if
    /// the feed stays empty (network/auth).
    private func waitForVideoCards(timeout: TimeInterval = 30) -> XCUIElementQuery? {
        let predicate = NSPredicate(format: "identifier BEGINSWITH 'video.card.'")
        let cards = app.descendants(matching: .any).matching(predicate)
        let anyCard = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count > 0"), object: cards)
        guard XCTWaiter().wait(for: [anyCard], timeout: timeout) == .completed else {
            return nil
        }
        return cards
    }

    /// Finds the first non-short video card from `cards` by checking that the
    /// card identifier's video-ID portion doesn't prefix a known Shorts pattern.
    /// Short cards are 9 characters; standard video IDs are 11.
    private func firstNonShortCard(from cards: XCUIElementQuery, maxCheck: Int = 20) -> XCUIElement? {
        for i in 0..<min(maxCheck, cards.count) {
            let card = cards.element(boundBy: i)
            let id = card.identifier  // "video.card.<videoId>"
            let videoId = String(id.dropFirst("video.card.".count))
            if videoId.count >= 11 { return card }
        }
        return nil
    }

    /// Opens the TOS player by tapping `card`, then waits for `tosPlayer.stateLabel`
    /// to appear. Returns the stateLabel element on success, nil if it never appeared.
    private func openTOSPlayer(from card: XCUIElement) -> XCUIElement? {
        if !card.isHittable {
            app.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: 100)
            Thread.sleep(forTimeInterval: 0.5)
        }
        card.tap()
        let stateLabel = app.descendants(matching: .any)
            .matching(identifier: "tosPlayer.stateLabel").firstMatch
        guard stateLabel.waitForExistence(timeout: 15) else { return nil }
        return stateLabel
    }

    // MARK: - Tests

    func testTOSPlayerIOSSmoke() throws {
        launchApp()

        // ── 1. Wait for the home feed ────────────────────────────────────────
        guard let cards = waitForVideoCards() else {
            throw XCTSkip("No video cards found — network unavailable or home feed empty")
        }
        guard let card = firstNonShortCard(from: cards) else {
            throw XCTSkip("No non-short video card found in first 20 cards")
        }
        print("[TOS-iOS] clicking card: \(card.identifier)")

        // ── 2. Register Darwin expectations BEFORE tapping ───────────────────
        // CRITICAL: notifications may fire during the cover-present animation
        // that precedes the stateLabel appearing. Create before tap.
        let readyNote   = XCTDarwinNotificationExpectation(notificationName: "com.void.ipockettube.tosplayer.ready")
        let playingNote = XCTDarwinNotificationExpectation(notificationName: "com.void.ipockettube.tosplayer.playing")

        // ── 3. Open TOS player ───────────────────────────────────────────────
        guard let stateLabel = openTOSPlayer(from: card) else {
            throw XCTSkip("tosPlayer.stateLabel did not appear — TOS player was not opened (check useTOSPlayerOnIOS=true and network)")
        }
        print("[TOS-iOS] ✓ player opened — stateLabel present")

        // ── 4. Wait for onPlayerReady ────────────────────────────────────────
        let readyResult = XCTWaiter().wait(for: [readyNote], timeout: 30)
        if readyResult == .completed {
            print("[TOS-iOS] ✓ onPlayerReady fired — iframe_api loaded")
        } else {
            throw XCTSkip("onPlayerReady never fired within 30 s — IFrame embed failed to load (network/YouTube availability)")
        }

        // ── 5. Wait for playing state ────────────────────────────────────────
        let playResult = XCTWaiter().wait(for: [playingNote], timeout: 15)
        let isPlaying: Bool
        if playResult == .completed {
            isPlaying = true
            print("[TOS-iOS] ✓ Darwin 'playing' notification received")
        } else {
            // Fallback: check AX state label directly.
            let labelText = stateLabel.label
            let valueText = stateLabel.value as? String ?? ""
            let stateStr  = labelText.isEmpty ? valueText : labelText
            isPlaying = stateStr == "playing" || stateStr == "buffering"
            print("[TOS-iOS] playing notification timed out — stateLabel='\(stateStr)'")
        }
        XCTAssertTrue(isPlaying, "TOS player did not reach 'playing' state within ~45 s — check network, allowsInlineMediaPlayback, and autoplay config")

        // ── 6. Tap back button → minimize to mini-player ─────────────────────
        let backButton = app.buttons["tosPlayer.backButton"]
        XCTAssertTrue(backButton.waitForExistence(timeout: 5), "tosPlayer.backButton not found")
        backButton.tap()
        print("[TOS-iOS] ✓ back button tapped — expecting mini-player to appear")

        // ── 7. Verify stateLabel gone (full-screen cover dismissed) ──────────
        let stateLabelGone = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: stateLabel
        )
        XCTAssertEqual(
            XCTWaiter().wait(for: [stateLabelGone], timeout: 5), .completed,
            "tosPlayer.stateLabel still visible after back button — cover was not dismissed"
        )
        print("[TOS-iOS] ✓ stateLabel gone — full-screen cover dismissed")

        // ── 8. Verify mini-player bar appeared ───────────────────────────────
        let miniBar = app.descendants(matching: .any)
            .matching(identifier: "tosPlayer.miniPlayerBar").firstMatch
        XCTAssertTrue(
            miniBar.waitForExistence(timeout: 5),
            "tosPlayer.miniPlayerBar did not appear after back-button tap — TOSMiniPlayerView not shown"
        )
        print("[TOS-iOS] ✓ mini-player bar appeared — audio continues in background")
    }

    func testTOSPlayerIOSStopsOnClose() throws {
        launchApp()

        // ── 1. Open home feed and TOS player ────────────────────────────────
        guard let cards = waitForVideoCards() else {
            throw XCTSkip("No video cards found — network unavailable or home feed empty")
        }
        guard let card = firstNonShortCard(from: cards) else {
            throw XCTSkip("No non-short video card found in first 20 cards")
        }

        let readyNote = XCTDarwinNotificationExpectation(notificationName: "com.void.ipockettube.tosplayer.ready")
        guard let stateLabel = openTOSPlayer(from: card) else {
            throw XCTSkip("tosPlayer.stateLabel did not appear — TOS player was not opened")
        }

        let readyResult = XCTWaiter().wait(for: [readyNote], timeout: 30)
        guard readyResult == .completed else {
            throw XCTSkip("onPlayerReady never fired — IFrame embed failed to load (network/YouTube availability)")
        }
        print("[TOS-iOS] ✓ player ready, minimizing to mini-player")

        // ── 2. Tap back → mini-player ────────────────────────────────────────
        let backButton = app.buttons["tosPlayer.backButton"]
        XCTAssertTrue(backButton.waitForExistence(timeout: 5), "tosPlayer.backButton not found")
        backButton.tap()

        let miniBar = app.descendants(matching: .any)
            .matching(identifier: "tosPlayer.miniPlayerBar").firstMatch
        XCTAssertTrue(
            miniBar.waitForExistence(timeout: 5),
            "tosPlayer.miniPlayerBar did not appear after back-button tap"
        )
        print("[TOS-iOS] ✓ mini-player bar appeared")

        // ── 3. Tap ✕ (close) button → fully stopped ─────────────────────────
        let closeButton = app.buttons["tosPlayer.miniPlayer.closeButton"]
        XCTAssertTrue(closeButton.waitForExistence(timeout: 3), "tosPlayer.miniPlayer.closeButton not found")
        closeButton.tap()
        print("[TOS-iOS] ✓ close button tapped — expecting mini-player to disappear")

        // ── 4. Verify mini-player bar is gone ────────────────────────────────
        let miniBarGone = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: miniBar
        )
        XCTAssertEqual(
            XCTWaiter().wait(for: [miniBarGone], timeout: 5), .completed,
            "tosPlayer.miniPlayerBar still visible after close button — TOSPlayerStateStore.stop() did not fire"
        )
        print("[TOS-iOS] ✓ mini-player bar gone — TOS player fully stopped")

        // ── 5. Verify the full-screen cover does NOT reappear ────────────────
        // Give SwiftUI a moment to settle.
        Thread.sleep(forTimeInterval: 1.0)
        XCTAssertFalse(
            stateLabel.exists,
            "tosPlayer.stateLabel reappeared after stop — cover was unexpectedly re-presented"
        )
        print("[TOS-iOS] ✓ stateLabel absent — no unexpected re-presentation after stop")
    }

    /// Regression test for the landscape lock button — ported from
    /// PlayerView+ControlElements.swift to TOSPlayerView when it was discovered
    /// missing after TOS became the iOS default (it was never carried over).
    /// Mirrors AudioAndLandscapePlayerUITests.testLandscapeLockButtonExistsInPlayer/
    /// testLandscapeLockButtonToggles, adapted to TOS's helpers.
    func testTOSPlayerLandscapeLockButtonExistsAndToggles() throws {
        launchApp()
        guard let cards = waitForVideoCards() else {
            throw XCTSkip("No video cards found — network unavailable or home feed empty")
        }
        guard let card = firstNonShortCard(from: cards) else {
            throw XCTSkip("No non-short video card found in first 20 cards")
        }
        let playingNote = XCTDarwinNotificationExpectation(notificationName: "com.void.ipockettube.tosplayer.playing")
        guard openTOSPlayer(from: card) != nil else {
            throw XCTSkip("tosPlayer.stateLabel did not appear — TOS player was not opened")
        }
        guard XCTWaiter().wait(for: [playingNote], timeout: 20) == .completed else {
            throw XCTSkip("playing notification never fired — IFrame embed failed to load")
        }

        // Controls (including the lock button) are hidden until tapped — same
        // pattern as showControls() in AudioAndLandscapePlayerUITests. Tap the
        // player area (the gesture overlay isn't accessibility-exposed, so use a
        // raw coordinate) to reveal them. Must wait for "playing" first — tapping
        // while paused calls vm.play() instead of showControls().
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        // Let the controls' 0.2s fade-in animation settle before probing hittability.
        Thread.sleep(forTimeInterval: 0.5)

        let lockButton = app.buttons["tosPlayer.landscapeLockButton"]
        XCTAssertTrue(lockButton.waitForExistence(timeout: 10),
                      "tosPlayer.landscapeLockButton must appear in the player controls overlay")
        XCTAssertTrue(lockButton.isHittable, "Landscape lock button must be tappable once controls are shown")

        // Tap to lock landscape.
        lockButton.tap()
        XCTAssertEqual(app.state, .runningForeground,
                       "App must remain running after tapping the landscape lock button")
        Thread.sleep(forTimeInterval: 2)

        // Tap again to unlock — re-reveal controls first since they may have
        // auto-hidden during the 2s wait.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertTrue(lockButton.waitForExistence(timeout: 5), "Lock button must still exist after first tap")
        lockButton.tap()
        XCTAssertEqual(app.state, .runningForeground,
                       "App must remain running after unlocking")
    }

    /// Regression test for GitHub #111: "Tap on video to move the slider
    /// stops playback instead of showing and bringing up only the slider".
    ///
    /// Root cause: TOSSwipeNavigationOverlay's tap recognizer is attached to
    /// the window (so it observes touches outside its own hit-testing view)
    /// with cancelsTouchesInView=false — deliberately, so the PAN gesture
    /// doesn't steal YouTube's native bottom scrubber drag. The same setting
    /// applies to the TAP recognizer, so a tap in the video area reaches BOTH
    /// our showControls() handler AND YouTube's own native tap-to-toggle-play
    /// handler on the underlying <video> element — confirmed via device log:
    /// a "tick state: 1 → 2" (playing → paused) lands within ~100-300ms of
    /// the tap, consistently reproducible with genuine (non-stalled) playback.
    ///
    /// Fix (TOSPlayerView.swift onTap): rather than trying to block/cancel the
    /// touch at the UIKit layer (tried and reverted — disrupted SwiftUI's own
    /// button touch tracking, breaking the back button and landscape lock
    /// button), this detects the spurious pause after the fact and undoes it
    /// — so a brief pause→play flicker is expected and acceptable; what must
    /// NOT happen is the video staying paused.
    func testTOSPlayerTapToShowControlsDoesNotStopPlaybackDiagnostic() throws {
        launchApp()
        guard let cards = waitForVideoCards() else {
            throw XCTSkip("No video cards found — network unavailable or home feed empty")
        }
        guard let card = firstNonShortCard(from: cards) else {
            throw XCTSkip("No non-short video card found in first 20 cards")
        }
        let playingNote = XCTDarwinNotificationExpectation(notificationName: "com.void.ipockettube.tosplayer.playing")
        guard openTOSPlayer(from: card) != nil else {
            throw XCTSkip("tosPlayer.stateLabel did not appear — TOS player was not opened")
        }
        guard XCTWaiter().wait(for: [playingNote], timeout: 20) == .completed else {
            throw XCTSkip("playing notification never fired — IFrame embed failed to load")
        }
        // Let controls auto-hide first, matching the reported scenario exactly
        // ("after a few seconds... slider and control elements disappear").
        Thread.sleep(forTimeInterval: 5)

        let spuriousPause = XCTDarwinNotificationExpectation(notificationName: "com.void.ipockettube.tosplayer.state.2")
        // Tap mid-screen — well above the native controls bar (bottom ~12%).
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).tap()

        let pauseResult = XCTWaiter().wait(for: [spuriousPause], timeout: 2)
        guard pauseResult == .completed else {
            // No pause at all — the ideal outcome.
            return
        }
        // A pause happened — TOSPlayerView's recovery logic polls for up to
        // 1s and should bring playback back. Give it a margin beyond that.
        let resumedNote = XCTDarwinNotificationExpectation(notificationName: "com.void.ipockettube.tosplayer.playing")
        let resumeResult = XCTWaiter().wait(for: [resumedNote], timeout: 3)
        XCTAssertEqual(resumeResult, .completed,
            "Tap caused a spurious pause and playback never resumed — TOSPlayerView's detect-and-undo recovery did not fire")
    }

    /// Regression test for GitHub #51/#78 follow-up: watch history still didn't
    /// record after the auth-token-propagation fix landed. Live device log
    /// showed why: `[watchtime] saveProgress skipped — historyState=enabled
    /// duration=0.0s` — TOSPlayerViewModel.duration was captured once on the
    /// very first poll ("ready", before video.duration had loaded) and never
    /// refreshed, so WatchtimeTracker.checkpoint()'s `duration > 0` guard
    /// always failed on dismiss. Fixed by also refreshing duration from each
    /// "tick" message. This opens a video, waits long enough for several
    /// ticks, and checks the bridge actually reports a non-zero duration via
    /// the `tosplayer.duration.<seconds>` notification fired here for the test.
    func testTOSPlayerDurationUpdatesFromZeroAfterTicks() throws {
        launchApp()
        guard let cards = waitForVideoCards() else {
            throw XCTSkip("No video cards found — network unavailable or home feed empty")
        }
        guard let card = firstNonShortCard(from: cards) else {
            throw XCTSkip("No non-short video card found in first 20 cards")
        }
        // Register BOTH expectations before opening the player — duration
        // becomes known within ~1 tick of "playing" firing (confirmed live:
        // ~280ms), so registering durationKnown only after waiting for
        // playingNote loses the race almost every time.
        let playingNote = XCTDarwinNotificationExpectation(notificationName: "com.void.ipockettube.tosplayer.playing")
        let durationKnown = XCTDarwinNotificationExpectation(notificationName: "com.void.ipockettube.tosplayer.durationknown")
        guard openTOSPlayer(from: card) != nil else {
            throw XCTSkip("tosPlayer.stateLabel did not appear — TOS player was not opened")
        }
        guard XCTWaiter().wait(for: [playingNote], timeout: 20) == .completed else {
            throw XCTSkip("playing notification never fired — IFrame embed failed to load")
        }
        let result = XCTWaiter().wait(for: [durationKnown], timeout: 10)
        XCTAssertEqual(result, .completed,
            "REGRESSION #51/#78: duration never became known from tick — watch history checkpoint would be skipped on dismiss")
    }
}
#endif // os(iOS)
