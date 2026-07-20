import XCTest

// MARK: - HLSResolutionUITests
//
// Verifies that a NON-EMBEDDABLE video plays at ≥720p via the authenticated
// WEB_CREATOR adaptive path — no rqh=1 streams, no pot= tokens.
//
// 360p is the muxed-only fallback (itag=18). If Auto quality resolves ≤360p it
// means every adaptive-stream client in exhaustiveRetry failed and the app fell
// back to the lowest-quality muxed stream.  That is a regression.
//
// Video Wu8xNx4njoM is embedding-disabled: TVEmbedded returns "This video is
// unavailable", so ALL adaptive clients (TVHTML5, MWEB, Android, AndroidVR)
// return rqh=1 streams which we skip without a pot= token.
// The fix: WEB_CREATOR with Bearer auth is exempt from rqh=1. When signed in
// (auth token loaded from Keychain, survives --uitesting-reset-settings),
// the WebCreator path returns 1080p+ adaptive streams that compose via
// AVMutableComposition.
//
// Failure means WebCreator auth is broken (signInRequired) or rqh= check is
// catching WEB_CREATOR streams incorrectly.
//
// Verification: Stats for Nerds shows the current AVPlayerItem.presentationSize.
// The resolution label contains U+00D7 (×), e.g. "1920×1080 @ 30 fps".
// The test parses the height component and asserts it is ≥720.

#if os(iOS)

final class HLSResolutionUITests: XCTestCase {

    // Non-embeddable video: TVEmbedded returns "unavailable", ALL adaptive clients return
    // rqh=1.  Only the authenticated WEB_CREATOR path provides non-rqh adaptive streams.
    // Auth token comes from Keychain (set during sign-in, not cleared by --uitesting-reset-settings).
    private static let videoID = "Wu8xNx4njoM"

    // U+00D7 MULTIPLICATION SIGN — used as the separator in resolution labels.
    private static let cross = "\u{00D7}"

    // Require ≥720p: WEB_CREATOR adaptive path returns 720p–2160p streams.
    // 360p (muxed fallback) or any height <720 means the WebCreator path failed.
    private static let minimumHeight = 720

    private var app: XCUIApplication!

    // MARK: - Lifecycle

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = [
            "--uitesting",
            "--uitesting-reset-settings",
            "--uitesting-disable-tos-player-on-ios",
            "--uitesting-deeplink-video=\(Self.videoID)",
            "--uitesting-show-controls",
            "--uitesting-disable-sponsorblock"
        ]
        app.launch()
    }

    override func tearDownWithError() throws {
        app = nil
    }

    // MARK: - Test

    /// Opens a non-embeddable video and asserts adaptive quality is ≥720p via WEB_CREATOR.
    ///
    /// Failure means WebCreator auth failed (signInRequired) or all adaptive paths returned
    /// rqh=1 and fell back to muxed 360p.
    /// Check device log for:
    ///   - WebCreator client fetch failed … signInRequired  → auth not injected
    ///   - [WebCreator[1]/adaptive] skipping rqh=1         → rqh detection false-positive
    ///   - [Android[1]] All adaptive failed — trying muxed → WebCreator path exhausted
    func testAutoQualityAbove360p() throws {
        // ── Step 1: Wait for player to open ──────────────────────────────────
        guard app.staticTexts["player.titleLabel"].firstMatch.waitForExistence(timeout: 25) else {
            try captureAndSkip("Player did not open within 25 s — network unavailable", in: app)
        }

        // ── Step 2: Wait for playback to be ready ────────────────────────────
        let playPause = app.buttons["player.playPauseButton"].firstMatch
        guard playPause.waitForExistence(timeout: 15) else {
            try captureAndSkip("play/pause button never appeared", in: app)
        }
        let enabledPred = NSPredicate(format: "enabled == true")
        let enabledExp = XCTNSPredicateExpectation(predicate: enabledPred, object: playPause)
        guard XCTWaiter().wait(for: [enabledExp], timeout: 90) == .completed else {
            captureState("video not ready after 90 s", in: app)
            XCTFail(
                "Video did not become ready within 90 s. " +
                "exhaustiveRetry must complete and deliver a playable stream. " +
                "Check device log for client phase errors."
            )
            return
        }
        UITestHelpers.assertNoPlayerErrorBanner(in: app, videoTitle: "HLS resolution")

        // Stats for Nerds is auto-enabled by --uitesting-stats-for-nerds; the observer
        // fires every 0.5 s and will have populated the resolution row by now.

        // ── Step 3: Read resolution from Stats overlay ────────────────────────
        let resLabel = currentResolutionLabel() ?? "nil"
        captureState("resolution: \(resLabel)", in: app)

        // ── Step 4: Assert resolution ≥720p ─────────────────────────────────
        let height = resolutionHeight(from: resLabel)
        XCTAssertGreaterThanOrEqual(
            height, Self.minimumHeight,
            "Auto quality is \(height)p (label: '\(resLabel)') — expected ≥720p. " +
            "WEB_CREATOR adaptive path failed. Check device log for: " +
            "WebCreator signInRequired (auth not injected), rqh=1 false-positive on WEB_CREATOR streams, " +
            "or exhaustiveRetry muxed fallback."
        )
    }

    // MARK: - Helpers

    /// Returns the label of the first static text containing "×" (U+00D7).
    /// The Stats for Nerds overlay formats resolution as "W×H @ fps".
    private func currentResolutionLabel() -> String? {
        let predicate = NSPredicate(format: "label CONTAINS %@", Self.cross)
        let el = app.staticTexts.matching(predicate).firstMatch
        return el.exists ? el.label : nil
    }

    /// Parses the height (pixels after "×") from a label like "1280×720 @ 30 fps".
    /// Returns 0 if the label cannot be parsed.
    private func resolutionHeight(from label: String) -> Int {
        guard let crossRange = label.range(of: Self.cross) else { return 0 }
        let afterCross = String(label[crossRange.upperBound...])
        let digits = afterCross.prefix(while: { $0.isNumber })
        return Int(digits) ?? 0
    }
}

#endif // os(iOS)
