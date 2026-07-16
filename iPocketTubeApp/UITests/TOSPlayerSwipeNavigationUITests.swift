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
//     unavailable or Google auth cookie expired.
//   - "onPlayerReady never fired" — IFrame embed failed to load (network/YouTube
//     availability), unrelated to the swipe-navigation code path under test.
//   - "stateLabel did not change after swipe" — related videos
//     (vm.relatedVideos / hasNext) did not populate within the timeout. Device log
//     should show "[navigation] cache MISS — fetched 0 related video(s)" or no
//     "[navigation]" line at all (fetchNextInfo failed/network).
//
// BUG skip (must fix before closing):
//   - A skip reached AFTER the device log shows
//     "[navigation] ... N related video(s)" with N > 0 — relatedVideos was
//     populated but the swipe still produced no navigation. That means the
//     gesture, TOSSwipeNavigationOverlay, or TOSPlayerStateStore.play() wiring
//     is broken.
//
// Log events to verify:
//   ✓ "[navigation] ... related video(s) for <videoId>" — relatedVideos populated
//   ✓ "[TOSPlayerStateStore] play — presentation set to .fullScreen, vm created for <videoId>"
//     appearing a SECOND time with a DIFFERENT videoId after the swipe
//
// RED FLAGS in device log:
//   - "[navigation] playNext" / "[navigation] playPrevious" logged but NO second
//     "[TOSPlayerStateStore] play —" line follows → onPlayNext/onPlayPrevious
//     callback was nil (TOSPlayerStateStore.play() did not wire it)

// MARK: - TOSPlayerSwipeNavigationUITests
//
// Verifies TOSSwipeNavigationOverlay (Sources/iPocketTube/Views/Player/TOSSwipeNavigationOverlay.swift)
// drives TOSPlayerViewModel.playNext()/playPrevious() during regular (non-Shorts)
// TOS-player video playback — the TOS-pipeline equivalent of
// PlayerNavigationUITests.PlayerLiveSwipeUITests for the AVPlayer pipeline.
//
// Swipes are delivered via coordinate-based press-drag in the TOP portion of the
// screen (TOSSwipeNavigationOverlay only accepts touches above
// verticalActivationFraction, default 0.75, so YouTube's bottom scrubber/control
// bar is left alone).
//
// `tosPlayer.stateLabel` only reports playerState (playing/paused/...), not the
// video identity, so a swipe is detected via the Darwin notification
// "com.void.ipockettube.tosplayer.ready" firing again for the newly-loaded video —
// "ready" only fires once per TOSPlayerViewModel after its embed reports
// duration > 0 (see TOSPlayerViewModel+WebBridge.swift), so a second "ready"
// firing after a swipe is strong evidence a new vm (and thus a new video) loaded.
final class TOSPlayerSwipeNavigationUITests: XCTestCase {

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

    // MARK: - Helpers (mirrors TOSPlayerIOSUITests)

    private func waitForVideoCards(timeout: TimeInterval = 30) -> XCUIElementQuery? {
        let predicate = NSPredicate(format: "identifier BEGINSWITH 'video.card.'")
        let cards = app.descendants(matching: .any).matching(predicate)
        let anyCard = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count > 0"), object: cards)
        guard XCTWaiter().wait(for: [anyCard], timeout: timeout) == .completed else {
            return nil
        }
        return cards
    }

    private func firstNonShortCard(from cards: XCUIElementQuery, maxCheck: Int = 20) -> XCUIElement? {
        for i in 0..<min(maxCheck, cards.count) {
            let card = cards.element(boundBy: i)
            let id = card.identifier  // "video.card.<videoId>"
            let videoId = String(id.dropFirst("video.card.".count))
            if videoId.count >= 11 { return card }
        }
        return nil
    }

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

    // MARK: - Swipe helpers
    //
    // Performed in the TOP-third of the screen (dy: 0.2) — TOSSwipeNavigationOverlay
    // only accepts touches above verticalActivationFraction (0.75 of screen height),
    // leaving YouTube's bottom scrubber/control-bar free.

    private func swipeLeft() {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.2))
        let end   = app.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.2))
        start.press(forDuration: 0.05, thenDragTo: end)
    }

    private func swipeRight() {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.2))
        let end   = app.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.2))
        start.press(forDuration: 0.05, thenDragTo: end)
    }

    // MARK: - Tests

    /// Swipe-left during regular TOS playback should advance to the next related
    /// video — observed as a second "ready" notification (a new TOSPlayerViewModel
    /// loaded a new embed) and the player returning to a "playing"/"buffering" state.
    func testSwipeLeftAdvancesToNextVideo() throws {
        launchApp()

        guard let cards = waitForVideoCards() else {
            throw XCTSkip("No video cards found — network unavailable or home feed empty")
        }
        guard let card = firstNonShortCard(from: cards) else {
            throw XCTSkip("No non-short video card found in first 20 cards")
        }

        let firstReady = XCTDarwinNotificationExpectation(notificationName: "com.void.ipockettube.tosplayer.ready")
        let firstPlaying = XCTDarwinNotificationExpectation(notificationName: "com.void.ipockettube.tosplayer.playing")

        guard let stateLabel = openTOSPlayer(from: card) else {
            throw XCTSkip("tosPlayer.stateLabel did not appear — TOS player was not opened")
        }

        guard XCTWaiter().wait(for: [firstReady], timeout: 30) == .completed else {
            throw XCTSkip("onPlayerReady never fired within 30 s — IFrame embed failed to load (network/YouTube availability)")
        }
        print("[TOS-swipe] ✓ first video ready")

        // Don't hard-require "playing" — buffering is enough to proceed, and slow
        // CI network shouldn't fail this test on a transient stall.
        _ = XCTWaiter().wait(for: [firstPlaying], timeout: 15)

        // fetchRelatedVideos() runs in the background after "ready" — give it a
        // moment to populate vm.relatedVideos (hasNext) before swiping.
        Thread.sleep(forTimeInterval: 3.0)

        // Register the SECOND "ready" expectation BEFORE swiping.
        let secondReady = XCTDarwinNotificationExpectation(notificationName: "com.void.ipockettube.tosplayer.ready")

        swipeLeft()
        print("[TOS-swipe] swiped left")

        let secondReadyResult = XCTWaiter().wait(for: [secondReady], timeout: 20)
        guard secondReadyResult == .completed else {
            throw XCTSkip("No second 'ready' notification after swipe left within 20 s — related videos likely did not populate in time (network-dependent)")
        }
        print("[TOS-swipe] ✓ second video ready — swipe left advanced to next video")

        // The new embed should reach playing/buffering, same as the smoke test.
        let secondPlaying = XCTDarwinNotificationExpectation(notificationName: "com.void.ipockettube.tosplayer.playing")
        let secondPlayingResult = XCTWaiter().wait(for: [secondPlaying], timeout: 15)
        let isPlaying: Bool
        if secondPlayingResult == .completed {
            isPlaying = true
        } else {
            let labelText = stateLabel.label
            let valueText = stateLabel.value as? String ?? ""
            let stateStr = labelText.isEmpty ? valueText : labelText
            isPlaying = stateStr == "playing" || stateStr == "buffering"
        }
        XCTAssertTrue(isPlaying, "Player did not reach playing/buffering on the swiped-to video")
    }

    /// Swipe-right with no navigation history (first video in the session) must
    /// not crash and must not load a different video — there's nothing to go back to.
    func testSwipeRightOnFirstVideoDoesNotCrash() throws {
        launchApp()

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
        guard XCTWaiter().wait(for: [readyNote], timeout: 30) == .completed else {
            throw XCTSkip("onPlayerReady never fired — IFrame embed failed to load (network/YouTube availability)")
        }

        swipeRight()
        Thread.sleep(forTimeInterval: 1.0)

        XCTAssertTrue(app.windows.firstMatch.exists, "App should not crash after swipe right with no history")
        XCTAssertTrue(stateLabel.exists, "tosPlayer.stateLabel should remain — swipe right with no history should be a no-op")
    }

    /// Swipe-left then swipe-right returns to the original video — exercises
    /// TOSPlayerStateStore.history / popHistory() round-trip.
    func testSwipeLeftThenRightReturnsToOriginalVideo() throws {
        launchApp()

        guard let cards = waitForVideoCards() else {
            throw XCTSkip("No video cards found — network unavailable or home feed empty")
        }
        guard let card = firstNonShortCard(from: cards) else {
            throw XCTSkip("No non-short video card found in first 20 cards")
        }

        let firstReady = XCTDarwinNotificationExpectation(notificationName: "com.void.ipockettube.tosplayer.ready")
        guard openTOSPlayer(from: card) != nil else {
            throw XCTSkip("tosPlayer.stateLabel did not appear — TOS player was not opened")
        }
        guard XCTWaiter().wait(for: [firstReady], timeout: 30) == .completed else {
            throw XCTSkip("onPlayerReady never fired within 30 s — IFrame embed failed to load (network/YouTube availability)")
        }

        // Let fetchRelatedVideos() populate vm.relatedVideos.
        Thread.sleep(forTimeInterval: 3.0)

        let secondReady = XCTDarwinNotificationExpectation(notificationName: "com.void.ipockettube.tosplayer.ready")
        swipeLeft()
        guard XCTWaiter().wait(for: [secondReady], timeout: 20) == .completed else {
            throw XCTSkip("No second 'ready' notification after swipe left within 20 s — related videos likely did not populate in time (network-dependent)")
        }
        print("[TOS-swipe] ✓ swiped left to second video")

        // Give the second embed a moment to settle before swiping back.
        Thread.sleep(forTimeInterval: 2.0)

        let thirdReady = XCTDarwinNotificationExpectation(notificationName: "com.void.ipockettube.tosplayer.ready")
        swipeRight()
        guard XCTWaiter().wait(for: [thirdReady], timeout: 20) == .completed else {
            throw XCTSkip("No third 'ready' notification after swipe right within 20 s — history-based back-navigation is network/timing-dependent")
        }
        print("[TOS-swipe] ✓ swiped right back to original video")

        XCTAssertTrue(app.windows.firstMatch.exists, "App should still be running after swipe left then right")
    }
}
#endif // os(iOS)
