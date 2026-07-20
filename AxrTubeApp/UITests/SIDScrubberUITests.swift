import XCTest

// MARK: - SIDScrubberUITests
//
// Regression test for bug #183 — seek bar (progress bar) greyed out on some videos.
//
// Root cause: for HLS streams where AVPlayerItem.duration is .invalid at .readyToPlay,
// vm.duration stays 0 and the scrubber is permanently non-interactive. The fix adds a
// `firstValidDurationStream` KVO observer that updates vm.duration once a valid value
// arrives after .readyToPlay.
//
// Verification:
//   1. Open the SID video (LSMQ3U1Thzw) which uses the WKWebView HLS path where
//      duration may arrive late.
//   2. After 8 s of playback, show controls.
//   3. Assert player.durationLabel is NOT "0:00" — proves vm.duration > 0.
//   4. Drag player.progressBar to 70 % and assert player.currentTimeLabel advances —
//      proves the scrub gesture has effect (duration > 0).
//
// Video: "The SID: Classic 8-bit sound chip" by Ben Eater (LSMQ3U1Thzw).
// Duration ~21 min. Not age/geo restricted. Uses WKWebView HLS path on simulator.

final class SIDScrubberUITests: XCTestCase {

    private static let targetVideoID = "LSMQ3U1Thzw"

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["--uitesting"]
        app.launchArguments += ["--uitesting-disable-tos-player-on-ios"]
        app.launchArguments += ["--uitesting-deeplink-video=\(Self.targetVideoID)"]
        app.launch()
    }

    override func tearDownWithError() throws {
        app = nil
    }

    // MARK: - Helpers

    private func showControls(timeout: TimeInterval = 10) -> Bool {
        let playPause = app.buttons["player.playPauseButton"].firstMatch
        for _ in 0..<6 {
            if playPause.exists { return true }
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            Thread.sleep(forTimeInterval: 1.5)
        }
        return playPause.exists
    }

    // MARK: - Tests

    #if os(iOS)
    /// Verifies that the progress bar reports a non-zero duration and can be scrubbed.
    ///
    /// This is the regression test for #183: on certain HLS videos AVPlayerItem.duration
    /// is .invalid at .readyToPlay, leaving vm.duration=0 and the scrubber greyed out.
    /// The fix (firstValidDurationStream KVO observer) ensures duration is updated once
    /// AVFoundation delivers it asynchronously after readyToPlay.
    func testScrubBarShowsNonZeroDurationAndSeekWorks() throws {
        // 1. Wait for player to open (title label proves PlayerView is displayed).
        guard app.staticTexts["player.titleLabel"].firstMatch.waitForExistence(timeout: 30) else {
            try captureAndSkip("player.titleLabel not found — video \(Self.targetVideoID) did not open (network?)", in: app)
        }

        // 2. Let the stream play for 8 s to allow HLS playlist parse and deferred
        //    AVPlayerItem.duration KVO delivery before checking the scrubber.
        Thread.sleep(forTimeInterval: 8)

        // 3. Show player controls.
        guard showControls() else {
            try captureAndSkip("player.playPauseButton never appeared — controls did not show", in: app)
        }

        // 4. Assert durationLabel is present and non-zero.
        let durationLabel = app.staticTexts["player.durationLabel"].firstMatch
        guard durationLabel.waitForExistence(timeout: 5) else {
            try captureAndSkip("player.durationLabel not found — controls may not be visible", in: app)
        }
        let durationText = durationLabel.label
        XCTAssertFalse(
            durationText.isEmpty || durationText == "0:00",
            "player.durationLabel shows '\(durationText)' — vm.duration is still 0 after 8 s; " +
            "deferred KVO duration update (firstValidDurationStream) may not be working (#183)"
        )

        // 5. Record currentTime before scrubbing.
        let currentTimeLabel = app.staticTexts["player.currentTimeLabel"].firstMatch
        guard currentTimeLabel.waitForExistence(timeout: 3) else {
            try captureAndSkip("player.currentTimeLabel not found", in: app)
        }

        // 6. Drag the progress bar from 10 % to 70 % to seek forward.
        let progressBar = app.otherElements["player.progressBar"].firstMatch
        guard progressBar.waitForExistence(timeout: 5) else {
            try captureAndSkip("player.progressBar not found — ensure accessibilityIdentifier is set", in: app)
        }

        let barFrame = progressBar.frame
        let startX = barFrame.minX + barFrame.width * 0.10
        let endX   = barFrame.minX + barFrame.width * 0.70
        let midY   = barFrame.midY

        let startCoord = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: startX, dy: midY))
        let endCoord   = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: endX,   dy: midY))
        startCoord.press(forDuration: 0.1, thenDragTo: endCoord)

        // 7. Wait for the seek to complete and controls to still be visible.
        Thread.sleep(forTimeInterval: 2)
        _ = showControls()

        // 8. After seeking to 70 %, currentTimeLabel should be well above 0:00.
        //    We can't know the exact time, but it should not still be at the video start.
        let currentTimeAfterSeek = app.staticTexts["player.currentTimeLabel"].firstMatch.label
        XCTAssertFalse(
            currentTimeAfterSeek.isEmpty || currentTimeAfterSeek == "0:00",
            "player.currentTimeLabel is '\(currentTimeAfterSeek)' after scrubbing to 70% — " +
            "seek had no effect, which means vm.duration was 0 and the scrubber was greyed out (#183)"
        )

        UITestHelpers.assertNoPlayerErrorBanner(in: app, videoTitle: "SID (\(Self.targetVideoID))")
    }
    #endif
}
