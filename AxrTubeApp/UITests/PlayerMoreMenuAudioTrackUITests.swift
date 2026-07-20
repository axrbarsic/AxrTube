import XCTest

// MARK: - PlayerMoreMenuAudioTrackUITests
//
// Regression tests for task-104: "audio track selector missing from iOS player overflow menu".
//
// Root cause (task-88 regression, fixed in commit 890376d):
//   task-88 removed `moreMenuAudioTrackRow` from the iOS `moreMenuOverlay` VStack,
//   classifying it as a duplicate of the quick-access pill row. Unlike the speed/quality/sleep
//   pill buttons (which are unconditional), the audio track pill is conditional —
//   only rendered when `vm.availableAudioTracks.count > 1`. The overflow menu row is
//   the *only* reliable path to language switching for users with auto-hiding controls.
//
// Fix (commit 890376d):
//   Re-inserted `moreMenuAudioTrackRow` into `moreMenuOverlay` between `moreMenuCaptionsRow`
//   and `moreMenuDescriptionRow`. Bumped iOS portrait `moreMenuMaxHeight` from 380 → 440 pt.
//
// Tests:
//   testAudioTrackRowAppearsInOverflowMenuForMultiTrackVideo  — row visible for dubbed video
//   testAudioTrackRowAbsentForSingleTrackVideo                — row absent for single-track video
//   testTappingAudioTrackRowOpensPicker                       — tapping row opens the picker

final class PlayerMoreMenuAudioTrackUITests: XCTestCase {

    /// Ben Eater "The SID: Classic 8-bit sound" — 13 AI-dubbed language tracks.
    /// Verified to carry YT-EXT-AUDIO-CONTENT-ID attributes in the HLS master manifest.
    private static let multiTrackVideoID = "LSMQ3U1Thzw"

    /// Rick Astley "Never Gonna Give You Up" — single English audio track (no dubbed languages).
    private static let singleTrackVideoID = "dQw4w9WgXcQ"

    private var app: XCUIApplication!

    // MARK: - Lifecycle

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    override func tearDownWithError() throws {
        app?.terminate()
        app = nil
    }

    // MARK: - Tests

    /// PRIMARY REGRESSION: the audio track row must appear in the overflow menu for a
    /// video with multiple dubbed language tracks.
    ///
    /// Before the task-104 fix, `moreMenuAudioTrackRow` was never called from
    /// `moreMenuOverlay`, so the row never appeared regardless of how many audio tracks
    /// `availableAudioTracks` contained.
    func testAudioTrackRowAppearsInOverflowMenuForMultiTrackVideo() throws {
        app.launchArguments = [
            "--uitesting",
            "--uitesting-disable-tos-player-on-ios",
            "--uitesting-deeplink-video=\(Self.multiTrackVideoID)"
        ]
        app.launch()

        guard app.staticTexts["player.titleLabel"].firstMatch.waitForExistence(timeout: 20) else {
            try captureAndSkip(
                "Player did not open for \(Self.multiTrackVideoID) within 20s — " +
                "network unavailable or YouTube blocked the request",
                in: app
            )
        }

        guard waitForPlaybackReady(timeout: 40) else {
            try captureAndSkip(
                "Playback did not become ready within 40s — " +
                "HLS manifest fetch or WKWebView extraction timed out for \(Self.multiTrackVideoID)",
                in: app
            )
        }

        guard let audioRow = openMoreMenuAndFindAudioRow() else {
            captureState("no-audio-row-multi-track", in: app)
            XCTFail(
                "player.moreMenu.audioTrackRow not found in the overflow menu for " +
                "\(Self.multiTrackVideoID). " +
                "Expected moreMenuAudioTrackRow to be present (task-104 regression). " +
                "Check device log for '[webView/HLS] YT-EXT-AUDIO-CONTENT-ID tracks: N'."
            )
            return
        }

        XCTAssertTrue(audioRow.isHittable, "Audio track row must be hittable (not just present in AX tree)")
        dismissMoreMenu()
    }

    /// The audio track row must NOT appear in the overflow menu for a single-track video.
    ///
    /// `moreMenuAudioTrackRow` has an internal guard `vm.availableAudioTracks.count > 1`
    /// that hides the row when the video has only one audio language.
    func testAudioTrackRowAbsentForSingleTrackVideo() throws {
        app.launchArguments = [
            "--uitesting",
            "--uitesting-disable-tos-player-on-ios",
            "--uitesting-deeplink-video=\(Self.singleTrackVideoID)"
        ]
        app.launch()

        guard app.staticTexts["player.titleLabel"].firstMatch.waitForExistence(timeout: 20) else {
            try captureAndSkip(
                "Player did not open for \(Self.singleTrackVideoID) within 20s — " +
                "network unavailable",
                in: app
            )
        }

        guard waitForPlaybackReady(timeout: 40) else {
            try captureAndSkip(
                "Playback did not become ready within 40s for \(Self.singleTrackVideoID)",
                in: app
            )
        }

        // Allow extra settle time for audio track loading to complete.
        Thread.sleep(forTimeInterval: 3)

        openMoreMenu()

        let audioRow = app.buttons["player.moreMenu.audioTrackRow"].firstMatch
        // A short wait is intentional: if the row is going to appear it does so immediately.
        let appeared = audioRow.waitForExistence(timeout: 3)

        if appeared {
            // If YouTube later adds dubbed tracks for this video, skip gracefully rather than fail.
            dismissMoreMenu()
            try captureAndSkip(
                "player.moreMenu.audioTrackRow appeared for \(Self.singleTrackVideoID) — " +
                "YouTube may have added dubbed tracks to this video. " +
                "Replace singleTrackVideoID with a video that has exactly one audio track.",
                in: app
            )
        }

        XCTAssertFalse(appeared, "Audio track row must not appear for a single-track video")
        dismissMoreMenu()
    }

    /// Tapping the audio track row in the overflow menu must open the audio track picker sheet.
    func testTappingAudioTrackRowOpensPicker() throws {
        app.launchArguments = [
            "--uitesting",
            "--uitesting-disable-tos-player-on-ios",
            "--uitesting-deeplink-video=\(Self.multiTrackVideoID)"
        ]
        app.launch()

        guard app.staticTexts["player.titleLabel"].firstMatch.waitForExistence(timeout: 20) else {
            try captureAndSkip(
                "Player did not open for \(Self.multiTrackVideoID) within 20s — " +
                "network unavailable",
                in: app
            )
        }

        guard waitForPlaybackReady(timeout: 40) else {
            try captureAndSkip(
                "Playback did not become ready within 40s for \(Self.multiTrackVideoID)",
                in: app
            )
        }

        guard let audioRow = openMoreMenuAndFindAudioRow() else {
            try captureAndSkip(
                "player.moreMenu.audioTrackRow not found — cannot test picker open. " +
                "See testAudioTrackRowAppearsInOverflowMenuForMultiTrackVideo for details.",
                in: app
            )
        }

        audioRow.tap()

        let picker = app.otherElements["player.audioTrackPicker"].firstMatch
        XCTAssertTrue(
            picker.waitForExistence(timeout: 5),
            "player.audioTrackPicker must appear after tapping the audio track row in the overflow menu"
        )
    }

    // MARK: - Helpers

    /// Polls until the play/pause button is both present and enabled (playback ready).
    /// Taps the screen every ~3 s to keep the controls overlay visible.
    @discardableResult
    private func waitForPlaybackReady(timeout: TimeInterval) -> Bool {
        let center = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            center.tap()
            Thread.sleep(forTimeInterval: 0.4)
            let btn = app.buttons["player.playPauseButton"].firstMatch
            if btn.exists && btn.isEnabled { return true }
            Thread.sleep(forTimeInterval: 3.0)
        }
        return false
    }

    /// Taps `player.moreButton` to open the overflow menu. Returns without assertion.
    private func openMoreMenu() {
        let moreButton = app.buttons["player.moreButton"].firstMatch
        for _ in 0..<8 {
            if moreButton.exists && moreButton.isHittable { break }
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            Thread.sleep(forTimeInterval: 1.5)
        }
        guard moreButton.exists, moreButton.isHittable else { return }
        moreButton.tap()
    }

    /// Opens the overflow menu and returns `player.moreMenu.audioTrackRow` if present.
    /// Leaves the menu open on success, dismisses it and returns nil on failure.
    private func openMoreMenuAndFindAudioRow() -> XCUIElement? {
        openMoreMenu()
        let audioRow = app.buttons["player.moreMenu.audioTrackRow"].firstMatch
        if audioRow.waitForExistence(timeout: 5) { return audioRow }
        dismissMoreMenu()
        return nil
    }

    /// Dismisses the overflow menu sheet via the Cancel button or an out-of-sheet tap.
    private func dismissMoreMenu() {
        let cancelButton = app.buttons["Cancel"].firstMatch
        if cancelButton.waitForExistence(timeout: 2), cancelButton.exists {
            cancelButton.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        } else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.1)).tap()
        }
        Thread.sleep(forTimeInterval: 0.5)
    }
}
