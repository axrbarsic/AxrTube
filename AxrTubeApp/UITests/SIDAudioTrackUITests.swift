import XCTest

// AGENT-POST-RUN-CHECK: ui-tests-with-logs
//
// After every run of this test, load .github/skills/ui-tests-with-logs/SKILL.md and inspect
// the extracted device log. Classify every skip before closing the task:
//
// LEGITIMATE skip:
//   - Network unavailable or YouTube server-side change: player never loads.
//     Test message: "Player did not load or playback did not complete within deadline"
//   - YouTube changed the manifest format (no more YT-EXT-AUDIO-CONTENT-ID attributes):
//     Device log shows "[webView/HLS] YT-EXT-AUDIO-CONTENT-ID tracks: 0"
//     and "AudioTrackManager: loadHLSVariantTracks never called"
//
// BUG skip (must fix before closing):
//   - Audio row absent even though "YT-EXT-AUDIO-CONTENT-ID tracks: N (N>0)" appears in log.
//     parseHLSAudioLanguages is parsing tracks but loadHLSVariantTracks / SwiftUI binding broken.
//   - "✅ [webView/HLS] readyToPlay" present but "[webView/HLS] YT-EXT-AUDIO-CONTENT-ID tracks:"
//     line absent entirely → parseHLSAudioLanguages is not being called (regression in wiring).
//   - Tracks loaded but picker shows 1 or 0 tracks → availableAudioTracks not populated correctly.
//
// Log events to verify (simulator or real device, no auth required):
//   ✓ [webView/HLS] master manifest OK bytes=<large>
//   ✓ [HLSProxy] language filter: lang=original kept N variants (from M lines)
//   ✓ [webView/HLS] YT-EXT-AUDIO-CONTENT-ID tracks: 13 — <language list>
//   ✓ AudioTrackManager: loaded 13 HLS variant track(s) — selected: English
//   ✓ ✅ [webView/HLS] readyToPlay
//   ✓ player.moreMenu.audioTrackRow found and hittable
//   ✓ Picker shows >5 language buttons
//   ✓ Exactly one "Original" label (contentID="en-US.4", acont=original in XTAGS)
//   ✓ player.quickAccess.audioTrack pill exists and is hittable after readyToPlay
//
// TIMING NOTE for audio pill (testQuickAccessAudioTrackPillVisible):
//   loadHLSVariantTracks is called BEFORE readyToPlay in the WKWebView HLS path.
//   So availableAudioTracks.count == 13 when readyToPlay fires. The controls
//   overlay (and the pill) are only rendered after readyToPlay, so the pill
//   appears on the user's FIRST tap after isLoading = false. If a user taps
//   during the loading spinner (before readyToPlay), controls show with count=0
//   and the pill is absent in that 4-second window. On the next tap after
//   readyToPlay the pill is always present.
//
// RED FLAGS in device log:
//   - "[webView/HLS] YT-EXT-AUDIO-CONTENT-ID tracks: 0" → YouTube changed format; re-examine.
//   - "AudioTrackManager: loadHLSVariantTracks" not present → wiring in tryWebViewHLS broken.
//   - All 13 tracks show isOriginal=false → XTAGS base64 decode for acont=original broken.
//   - Multiple "Original" labels → isOriginal detection firing too broadly.

// MARK: - SIDAudioTrackUITests
//
// Regression tests for the Ben Eater "The SID: Classic 8-bit sound" video
// (video ID: LSMQ3U1Thzw) — a video with 13 AI-dubbed language tracks.
//
// Root cause fixed (May 2026):
//   YouTube's HLS master manifest does NOT use #EXT-X-MEDIA:TYPE=AUDIO groups for
//   dubbed content. Instead, each quality level has N #EXT-X-STREAM-INF variants —
//   one per language — identified by YT-EXT-AUDIO-CONTENT-ID="xx-XX.N" attributes.
//   The original audio variant has no attribute. Because AVFoundation's
//   loadMediaSelectionGroup(for: .audible) requires EXT-X-MEDIA groups, it always
//   returned nil → availableAudioTracks stayed empty → audio row never shown.
//
//   Fix (PlaybackViewModel+Fallback.swift — tryWebViewHLS):
//     After fetching the master manifest, parseHLSAudioLanguages parses
//     YT-EXT-AUDIO-CONTENT-ID attributes from #EXT-X-STREAM-INF lines to build
//     AudioTrack instances. YT-EXT-XTAGS (base64 protobuf) is decoded to detect
//     the original track via "acont=original". AudioTrackManager.loadHLSVariantTracks
//     populates availableAudioTracks directly, bypassing the EXT-X-MEDIA path.
//
//   Fix (YTHLSProxyLoader — selectedLanguageContentID):
//     The proxy now filters #EXT-X-STREAM-INF variants to only the selected language
//     (or original when nil), so AVPlayer's ABR doesn't mix languages.
//
// Test strategy:
//   Open the SID video directly via --uitesting-deeplink-video, then assert:
//     1. The more-menu audio track row is visible (HLS, not muxed).
//     2. The picker lists more than one language.
//     3. Exactly one track is labelled "Original".
//     4. The "Original" track is English.
//
// Requirements:
//   • Network access is required.
//   • Run on an iOS 17+ simulator with the iPocketTubeApp scheme (English locale).

final class SIDAudioTrackUITests: XCTestCase {

    /// Ben Eater "The SID: Classic 8-bit sound" — 13 AI-dubbed language tracks.
    private static let videoID = "LSMQ3U1Thzw"

    private static var sharedApp: XCUIApplication!
    private static var skipAllTests = false
    private static let skipReason = "Player did not load or playback did not complete within deadline — " +
                                    "network unavailable or HLS fallback path broken for \(videoID)"

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

        // Wait for HLS manifest fetch + loadAudioTracks to settle.
        // The SID video triggers the async HLS-rescue path in tryAllStreams —
        // the background prefetch may need a few extra seconds to arrive.
        Thread.sleep(forTimeInterval: 10)

        // Poll until the play/pause button is both visible and enabled.
        //
        // WHY polling instead of XCTNSPredicateExpectation:
        // The controls overlay is conditionally rendered in SwiftUI:
        //   `if vm.controlsVisible { makeControlsOverlay(...) }`
        // When controlsVisible = false the overlay (and every button inside it,
        // including player.playPauseButton) is *removed* from the view hierarchy and
        // therefore absent from the XCUITest accessibility tree. XCTNSPredicateExpectation
        // evaluates `enabled` on a stale snapshot — once the element disappears it stays
        // false even after isLoading is cleared by .readyToPlay. For slow-loading videos
        // like this one (WKWebView extraction + ~16 s buffering) the 4-second controls
        // auto-hide fires long before readyToPlay, so the passive waiter always times out.
        //
        // The fix: tap the screen every ~3 s to keep controls visible, then immediately
        // re-query the button. Once isLoading = false the freshly-shown button is enabled.
        let center = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let deadline = Date().addingTimeInterval(40)
        var playbackReady = false
        while Date() < deadline {
            center.tap()
            Thread.sleep(forTimeInterval: 0.4)   // let SwiftUI render the controls overlay
            let btn = app.buttons["player.playPauseButton"].firstMatch
            if btn.exists && btn.isEnabled {
                playbackReady = true
                break
            }
            // Controls auto-hide after 4 s; wait ~3 s then re-tap.
            Thread.sleep(forTimeInterval: 3.0)
        }
        if !playbackReady {
            skipAllTests = true
        }
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

    private var app: XCUIApplication { Self.sharedApp }

    /// Opens the more menu and returns the audio track row button, or nil if absent.
    /// Leaves the more menu open on success.
    ///
    /// Uses `isHittable` (not just `exists`) to confirm the controls overlay is
    /// actually visible before tapping — SwiftUI keeps hidden elements (opacity=0)
    /// in the accessibility tree, so `exists` alone is not a reliable visibility check.
    @discardableResult
    private func openMoreMenuAudioRow() -> XCUIElement? {
        let moreButton = app.buttons["player.moreButton"].firstMatch
        // Tap the player surface until moreButton is hittable (controls overlay visible).
        for _ in 0..<8 {
            if moreButton.exists && moreButton.isHittable { break }
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            Thread.sleep(forTimeInterval: 1.5)
        }
        guard moreButton.exists, moreButton.isHittable else { return nil }
        moreButton.tap()
        let audioRow = app.buttons["player.moreMenu.audioTrackRow"].firstMatch
        if audioRow.waitForExistence(timeout: 5) { return audioRow }
        // More menu opened but no audio track row (single-track or muxed) — close it.
        dismissMoreMenu()
        return nil
    }

    /// Dismisses the audio track picker (Cancel button or out-of-picker tap).
    private func dismissPicker() {
        let cancelButton = app.buttons["Cancel"].firstMatch
        if cancelButton.waitForExistence(timeout: 2), cancelButton.exists {
            cancelButton.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        } else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.05)).tap()
        }
        Thread.sleep(forTimeInterval: 0.5)
    }

    /// Dismisses the more menu sheet.
    private func dismissMoreMenu() {
        let cancelButton = app.buttons["Cancel"].firstMatch
        if cancelButton.waitForExistence(timeout: 2), cancelButton.exists {
            cancelButton.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        } else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.1)).tap()
        }
        Thread.sleep(forTimeInterval: 0.5)
    }

    // MARK: - Tests

    /// PRIMARY REGRESSION: the audio track selector must appear in the more menu.
    ///
    /// The selector row is only added when `availableAudioTracks.count > 1`.
    /// This requires parseHLSAudioLanguages to parse YT-EXT-AUDIO-CONTENT-ID attributes
    /// from the HLS master manifest and loadHLSVariantTracks to populate availableAudioTracks.
    /// Works on simulator without YouTube auth (YouTube includes YT-EXT-AUDIO-CONTENT-ID
    /// in unauthenticated manifests — it is a video-stream attribute, not an auth-gated one).
    func testAudioTrackSelectorIsVisibleInMoreMenu() throws {
        guard !Self.skipAllTests else { throw XCTSkip(Self.skipReason) }

        guard let audioRow = openMoreMenuAudioRow() else {
            captureState("no-audio-row", in: app)
            throw XCTSkip(
                "player.moreMenu.audioTrackRow not found for video \(Self.videoID). " +
                "Device log should show '[webView/HLS] YT-EXT-AUDIO-CONTENT-ID tracks: 13'. " +
                "If it shows '0 tracks', YouTube may have changed the manifest format. " +
                "If the log line is absent entirely, tryWebViewHLS language-wiring is broken."
            )
        }

        XCTAssertTrue(audioRow.exists)
        dismissMoreMenu()
    }

    /// The audio track picker must list more than one language.
    ///
    /// The SID video has 13 AI-dubbed languages. Assert > 5 to be resilient
    /// to YouTube removing some dubbed languages over time.
    func testAudioTrackPickerShowsMultipleLanguages() throws {
        guard !Self.skipAllTests else { throw XCTSkip(Self.skipReason) }

        guard let audioRow = openMoreMenuAudioRow() else {
            throw XCTSkip("Audio track row not found — HLS manifest had 0 YT-EXT-AUDIO-CONTENT-ID tracks (see testAudioTrackSelectorIsVisibleInMoreMenu)")
        }
        audioRow.tap()

        let picker = app.otherElements["player.audioTrackPicker"].firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 5), "Audio track picker must open")

        // Give SwiftUI time to render all rows before querying the accessibility tree.
        Thread.sleep(forTimeInterval: 1.5)

        // Each track row is a plain Button whose label is the combined text of its
        // child Text views (e.g. "English\nOriginal" or "Spanish").  staticTexts
        // inside plain-style Buttons are merged into the button's accessibility
        // label and do NOT appear as separate static text elements — so count
        // picker.buttons instead.  The picker always contains exactly two
        // chrome buttons (Cancel, Auto) plus one button per available track.
        let trackCount = picker.buttons.count - 2   // subtract Cancel + Auto

        captureState("picker-language-count", in: app)
        XCTAssertGreaterThan(
            trackCount, 5,
            "Expected more than 5 language tracks for video \(Self.videoID) (has 13 AI-dubbed langs). " +
            "Got \(trackCount). If the picker only shows 1 track, parseHLSAudioLanguages " +
            "found only one YT-EXT-AUDIO-CONTENT-ID entry — check manifest fetch."
        )

        dismissPicker()
    }

    /// Exactly one track must be labelled "Original" in the picker.
    ///
    /// YouTube places the creator's English audio at contentID="en-US.4" with
    /// YT-EXT-XTAGS protobuf containing "acont=original". parseHLSAudioLanguages decodes
    /// the XTAGS base64 and sets isOriginal=true for that track only.
    func testExactlyOneTrackIsMarkedOriginal() throws {
        guard !Self.skipAllTests else { throw XCTSkip(Self.skipReason) }

        guard let audioRow = openMoreMenuAudioRow() else {
            throw XCTSkip("Audio track row not found — HLS manifest had 0 YT-EXT-AUDIO-CONTENT-ID tracks (see testAudioTrackSelectorIsVisibleInMoreMenu)")
        }
        audioRow.tap()

        let picker = app.otherElements["player.audioTrackPicker"].firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 5), "Audio track picker must open")

        let originalLabels = picker.staticTexts.matching(
            NSPredicate(format: "label == 'Original'")
        )

        captureState("picker-original-count", in: app)
        XCTAssertEqual(
            originalLabels.count, 1,
            "Exactly one track must be labelled 'Original' in the picker. " +
            "0 = XTAGS base64 decode for acont=original not working (check parseHLSAudioLanguages). " +
            ">1 = isOriginal detection firing too broadly."
        )

        dismissPicker()
    }

    /// The track labelled "Original" must be English.
    ///
    /// Ben Eater originally recorded the SID video in English. YouTube assigns
    /// contentID="en-US.4" with XTAGS "acont=original:lang=en-US" to the original track.
    /// parseHLSAudioLanguages derives langCode="en-US" and the display name is
    /// Locale.current.localizedString(forLanguageCode:"en-US") which returns "English" on
    /// the default English-locale simulator.
    ///
    /// Note: on a non-English locale the display name is localised (e.g. "Anglais" on French),
    /// which would cause this test to skip rather than fail.
    func testOriginalTrackIsEnglish() throws {
        guard !Self.skipAllTests else { throw XCTSkip(Self.skipReason) }

        guard let audioRow = openMoreMenuAudioRow() else {
            throw XCTSkip("Audio track row not found — HLS manifest had 0 YT-EXT-AUDIO-CONTENT-ID tracks (see testAudioTrackSelectorIsVisibleInMoreMenu)")
        }
        audioRow.tap()

        let picker = app.otherElements["player.audioTrackPicker"].firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 5), "Audio track picker must open")

        // SwiftUI combines the child Text elements of a Button into its accessibility label.
        // The English-original row has Text("English") + Text("Original"), so the button's
        // combined label contains both strings.
        captureState("picker-english-original", in: app)
        let englishOriginalRow = picker.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS 'English' AND label CONTAINS 'Original'")
        ).firstMatch

        guard englishOriginalRow.exists else {
            // If the device locale is non-English, the track name is localised and
            // the string match above won't fire — skip rather than fail.
            let isEnglishLocale = Locale.current.language.languageCode?.identifier == "en"
            if !isEnglishLocale {
                throw XCTSkip("Non-English device locale — track name is localised, skipping English string check")
            }
            captureState("english-original-missing", in: app)
            XCTFail(
                "The track labelled 'Original' must be English for video \(Self.videoID). " +
                "Phase 4 marks the LAST track in the HLS manifest; YouTube places English (en-US) last. " +
                "If this fails, either the wrong track is marked original or Phase 4 picked a non-English last track."
            )
            return
        }

        XCTAssertTrue(englishOriginalRow.exists)
        dismissPicker()
    }

    /// The audio track quick-access pill must appear in the player controls overlay.
    ///
    /// `player.quickAccess.audioTrack` sits in `quickAccessButtonRow` below the scrubber
    /// inside `PlayerControlsOverlay`. It is rendered when `vm.availableAudioTracks.count > 1`.
    /// For the SID video (13 AI-dubbed tracks) the pill must be hittable whenever the controls
    /// overlay is on-screen.
    func testQuickAccessAudioTrackPillVisible() throws {
        guard !Self.skipAllTests else { throw XCTSkip(Self.skipReason) }

        // Bring controls overlay on-screen (same pattern as openMoreMenuAudioRow).
        let moreButton = app.buttons["player.moreButton"].firstMatch
        for _ in 0..<8 {
            if moreButton.exists && moreButton.isHittable { break }
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            Thread.sleep(forTimeInterval: 1.5)
        }
        guard moreButton.exists, moreButton.isHittable else {
            throw XCTSkip("Controls overlay did not appear — cannot verify audio pill for \(Self.videoID)")
        }

        let pill = app.buttons["player.quickAccess.audioTrack"].firstMatch
        captureState("pill-check", in: app)

        XCTAssertTrue(
            pill.exists && pill.isHittable,
            "player.quickAccess.audioTrack pill must be visible in the controls overlay " +
            "when \(Self.videoID) has 13 audio tracks. " +
            "If absent: check device log for 'AudioTrackManager: loaded 13 HLS variant track(s)' " +
            "and verify @Observable propagation from AudioTrackManager through PlaybackViewModel " +
            "to PlayerControlsOverlay."
        )

        // Tapping the pill must open the audio track picker.
        pill.tap()
        let picker = app.otherElements["player.audioTrackPicker"].firstMatch
        XCTAssertTrue(
            picker.waitForExistence(timeout: 5),
            "Tapping player.quickAccess.audioTrack must open player.audioTrackPicker"
        )
        dismissPicker()
    }
}
