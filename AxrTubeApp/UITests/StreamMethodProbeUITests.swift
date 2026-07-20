#if os(iOS)
import XCTest

// MARK: - StreamMethodProbeUITests
//
// One test per (stream method, video ID) pair.
//
// PURPOSE
// -------
// These tests do NOT assert a specific pass/fail outcome — they collect empirical
// data about which stream-fetching client works for which video.  A test PASSES
// when the video reaches readyToPlay; it FAILS when only an error banner appears
// or the player times out.  Both outcomes are valuable: failures tell us which
// paths YouTube has blocked for which content.
//
// HOW IT WORKS
// ------------
// Each test launches the app with TWO extra launch args:
//   --uitesting-deeplink-video=<videoId>        → open this specific video
//   --uitesting-force-stream-method=<method>    → bypass exhaustiveRetry race;
//                                                  call only this one client
//
// The app's AppEntry.swift parses --uitesting-force-stream-method and stores it in
// StreamMethodProbeSupport.forcedStreamMethod.  PlaybackViewModel+Fallback.swift
// reads that value at the top of exhaustiveRetry() and routes to probeStreamMethod()
// instead of the normal multi-path race.
//
// METHODS UNDER TEST (10)
// -----------------------
//   ios           iOS client (googleapis.com, c=IOS) — always has rqh=1 adaptive streams
//   ios-auth      iOS client + Bearer + pot= — usually HTTP 400 for TV-scoped tokens
//   tvembedded    WEB_EMBEDDED_PLAYER (nameID=56) — HLS for embeddable videos only
//   tvauth        TV client + Bearer auth — authenticated HLS, bypasses rqh=1
//   websafari     WEB + macOS Safari UA — HLS for embedding-disabled content
//   mweb          MWEB (iPad Safari UA) — HLS, not subject to embed restriction
//   android       Android client — CDN-signed adaptive, used for muxed fallback
//   android-vr    Oculus Quest client (nameID=28) — CDN-exempt from rqh=1/pot=
//   web-creator   WEB_CREATOR / YouTube Studio — rqh=1 exempt, requires Bearer
//   web-auth      WEB + Bearer (mirrors yt-dlp oauth) — no rqh=1 for signed-in users
//   wkwebview-hls WKWebView HLS extraction — reliable for rqh=1, slow (~3–9 s cold)
//
// VIDEO IDs UNDER TEST (8)
// ------------------------
//   dQw4w9WgXcQ  Rick Astley — public, embeddable, popular
//   9bZkp7q19f0  PSY Gangnam Style — high view count, sometimes rqh=1
//   LSMQ3U1Thzw  Ben Eater SID — rqh=1, multi-audio tracks
//   v2ZtAi2rDzA  rqh=1 worst-case (WKWebView HLS cold path)
//   Wu8xNx4njoM  Embedding-disabled (TVEmbedded returns "unavailable")
//   y9R5a76HPbU  nSolver regression video
//   Dy9ki9Q5nXs  Scrubber test video (standard public)
//   jNQXAC9IVRw  First YouTube video — very old format
//
// RESULTS TABLE
// -------------
// After running, fill in docs/playing-methods.md with ✅ PASS / ❌ FAIL / ⏱ TIMEOUT.
// See also the AGENT-POST-RUN-CHECK block below for log-based analysis.
//
// RUNNING
// -------
//   # Full matrix (parallel, iOS simulator):
//   xcodebuild test \
//     -workspace AxrTube.xcworkspace -scheme "iPocketTube" \
//     -destination 'platform=iOS Simulator,name=iPhone 16' \
//     -only-testing:iPocketTubeUITests/StreamMethodProbeUITests \
//     -parallel-testing-enabled YES -maximum-parallel-testing-workers 4 \
//     -resultBundlePath /tmp/stream-method-probe.xcresult
//
//   # Single probe:
//   -only-testing:iPocketTubeUITests/StreamMethodProbeUITests/testProbe_tvembedded__Wu8xNx4njoM

// AGENT-POST-RUN-CHECK: ui-tests-with-logs
//
// After running, extract device logs and grep for per-test evidence:
//   grep -E "\[probe\]" "$APP_LOG" | head -100
//   grep -E "readyToPlay|✅.*probe|❌.*probe|error.*probe" "$APP_LOG" | head -100
//
// Per-probe events to look for:
//   ✓ [probe] starting single-method probe: <method> for <videoId>
//   ✓ [probe] ✅ <method> succeeded for <videoId>    → PASS
//   ✗ [probe] ❌ <method> failed for <videoId>       → FAIL
//   ✗ [probe] ❌ <method> threw: <error> for <videoId> → FAIL (network/auth)
//
// RED FLAGS:
//   - "unknown method" → method string typo in test
//   - Probe succeeds but player shows error banner → race condition in UI state

final class StreamMethodProbeUITests: XCTestCase {

    // MARK: - Timeout

    /// Maximum seconds to wait for the player to reach readyToPlay for any method.
    /// wkwebview-hls can take up to ~9 s cold; add buffer for slow CI workers.
    private static let probeTimeout: TimeInterval = 90

    // MARK: - Core probe helper

    /// Launches the app with one specific stream method forced for one specific video,
    /// waits for success or failure, and asserts the video played.
    ///
    /// - Parameters:
    ///   - method: A value from `StreamMethodProbeSupport.knownMethods`.
    ///   - videoId: An 11-character YouTube video ID.
    ///   - requiresAuth: When true the test is skipped if the simulator has no auth token
    ///     stored in Keychain (tvauth / web-creator / web-auth / ios-auth paths).
    private func probe(_ method: String, _ videoId: String, requiresAuth: Bool = false) {
        continueAfterFailure = false

        let app = XCUIApplication()
        app.launchArguments = [
            "--uitesting",
            "--uitesting-disable-tos-player-on-ios",
            "--uitesting-deeplink-video=\(videoId)",
            "--uitesting-force-stream-method=\(method)",
            "--uitesting-show-controls",
            "--uitesting-disable-sponsorblock",
        ]
        app.launch()

        defer { app.terminate() }

        let titleLabel   = app.staticTexts["player.titleLabel"].firstMatch
        let errorBanner  = app.otherElements["player.errorBanner"].firstMatch
        let playPause    = app.buttons["player.playPauseButton"].firstMatch

        // Wait for either the title label or the error banner to appear.
        let appeared = titleLabel.waitForExistence(timeout: Self.probeTimeout)

        if !appeared {
            // Check if an error banner appeared instead (errorBanner may render before title).
            if errorBanner.exists {
                XCTFail("[\(method)/\(videoId)] error banner appeared — method failed or network error")
                return
            }
            // Check if errorBanner appeared during the wait period (may have appeared and gone)
            let spinnerGone = NSPredicate(format: "identifier == 'player.errorBanner'")
            let bannerExp = XCTNSPredicateExpectation(predicate: spinnerGone, object: app.otherElements)
            let _ = XCTWaiter().wait(for: [bannerExp], timeout: 2)
            if errorBanner.exists {
                XCTFail("[\(method)/\(videoId)] error banner appeared — method failed")
            } else {
                XCTFail("[\(method)/\(videoId)] player did not load within \(Int(Self.probeTimeout))s — timeout")
            }
            return
        }

        // Title appeared — wait for play button to become enabled (video is buffering/playing).
        let enabledPredicate = NSPredicate(format: "enabled == true")
        let playReadyExpectation = XCTNSPredicateExpectation(predicate: enabledPredicate,
                                                              object: playPause)
        let playReady = XCTWaiter().wait(for: [playReadyExpectation], timeout: 30) == .completed

        if errorBanner.exists {
            XCTFail("[\(method)/\(videoId)] error banner appeared after title load — method failed mid-play")
            return
        }

        // Capture resolution from the hidden player.probeStreamResult element.
        // probeStreamResult is set slightly after playPauseButton becomes enabled
        // (set by probeStreamMethod after tryAllStreams returns), so wait up to 8s
        // for it to appear rather than checking immediately.
        let probeResultEl = app.staticTexts["player.probeStreamResult"].firstMatch
        let _ = probeResultEl.waitForExistence(timeout: 8)
        let resolution = probeResultEl.exists ? probeResultEl.label : "?"
        print("[probe-result] \(method)/\(videoId): \(resolution)")
        XCTContext.runActivity(named: "stream: \(resolution)") { _ in }

        XCTAssertTrue(playReady, "[\(method)/\(videoId)] play button never became enabled after title appeared")
    }

    // MARK: - ios

    func testProbe_ios__dQw4w9WgXcQ()  { probe("ios", "dQw4w9WgXcQ") }
    func testProbe_ios__9bZkp7q19f0()  { probe("ios", "9bZkp7q19f0") }
    func testProbe_ios__LSMQ3U1Thzw()  { probe("ios", "LSMQ3U1Thzw") }
    func testProbe_ios__v2ZtAi2rDzA()  { probe("ios", "v2ZtAi2rDzA") }
    func testProbe_ios__Wu8xNx4njoM()  { probe("ios", "Wu8xNx4njoM") }
    func testProbe_ios__y9R5a76HPbU()  { probe("ios", "y9R5a76HPbU") }
    func testProbe_ios__Dy9ki9Q5nXs()  { probe("ios", "Dy9ki9Q5nXs") }
    func testProbe_ios__jNQXAC9IVRw()  { probe("ios", "jNQXAC9IVRw") }

    // MARK: - ios-auth

    func testProbe_iosauth__dQw4w9WgXcQ()  { probe("ios-auth", "dQw4w9WgXcQ", requiresAuth: true) }
    func testProbe_iosauth__9bZkp7q19f0()  { probe("ios-auth", "9bZkp7q19f0", requiresAuth: true) }
    func testProbe_iosauth__LSMQ3U1Thzw()  { probe("ios-auth", "LSMQ3U1Thzw", requiresAuth: true) }
    func testProbe_iosauth__v2ZtAi2rDzA()  { probe("ios-auth", "v2ZtAi2rDzA", requiresAuth: true) }
    func testProbe_iosauth__Wu8xNx4njoM()  { probe("ios-auth", "Wu8xNx4njoM", requiresAuth: true) }
    func testProbe_iosauth__y9R5a76HPbU()  { probe("ios-auth", "y9R5a76HPbU", requiresAuth: true) }
    func testProbe_iosauth__Dy9ki9Q5nXs()  { probe("ios-auth", "Dy9ki9Q5nXs", requiresAuth: true) }
    func testProbe_iosauth__jNQXAC9IVRw()  { probe("ios-auth", "jNQXAC9IVRw", requiresAuth: true) }

    // MARK: - tvembedded

    func testProbe_tvembedded__dQw4w9WgXcQ()  { probe("tvembedded", "dQw4w9WgXcQ") }
    func testProbe_tvembedded__9bZkp7q19f0()  { probe("tvembedded", "9bZkp7q19f0") }
    func testProbe_tvembedded__LSMQ3U1Thzw()  { probe("tvembedded", "LSMQ3U1Thzw") }
    func testProbe_tvembedded__v2ZtAi2rDzA()  { probe("tvembedded", "v2ZtAi2rDzA") }
    func testProbe_tvembedded__Wu8xNx4njoM()  { probe("tvembedded", "Wu8xNx4njoM") }
    func testProbe_tvembedded__y9R5a76HPbU()  { probe("tvembedded", "y9R5a76HPbU") }
    func testProbe_tvembedded__Dy9ki9Q5nXs()  { probe("tvembedded", "Dy9ki9Q5nXs") }
    func testProbe_tvembedded__jNQXAC9IVRw()  { probe("tvembedded", "jNQXAC9IVRw") }

    // MARK: - tvauth

    func testProbe_tvauth__dQw4w9WgXcQ()  { probe("tvauth", "dQw4w9WgXcQ", requiresAuth: true) }
    func testProbe_tvauth__9bZkp7q19f0()  { probe("tvauth", "9bZkp7q19f0", requiresAuth: true) }
    func testProbe_tvauth__LSMQ3U1Thzw()  { probe("tvauth", "LSMQ3U1Thzw", requiresAuth: true) }
    func testProbe_tvauth__v2ZtAi2rDzA()  { probe("tvauth", "v2ZtAi2rDzA", requiresAuth: true) }
    func testProbe_tvauth__Wu8xNx4njoM()  { probe("tvauth", "Wu8xNx4njoM", requiresAuth: true) }
    func testProbe_tvauth__y9R5a76HPbU()  { probe("tvauth", "y9R5a76HPbU", requiresAuth: true) }
    func testProbe_tvauth__Dy9ki9Q5nXs()  { probe("tvauth", "Dy9ki9Q5nXs", requiresAuth: true) }
    func testProbe_tvauth__jNQXAC9IVRw()  { probe("tvauth", "jNQXAC9IVRw", requiresAuth: true) }

    // MARK: - websafari

    func testProbe_websafari__dQw4w9WgXcQ()  { probe("websafari", "dQw4w9WgXcQ") }
    func testProbe_websafari__9bZkp7q19f0()  { probe("websafari", "9bZkp7q19f0") }
    func testProbe_websafari__LSMQ3U1Thzw()  { probe("websafari", "LSMQ3U1Thzw") }
    func testProbe_websafari__v2ZtAi2rDzA()  { probe("websafari", "v2ZtAi2rDzA") }
    func testProbe_websafari__Wu8xNx4njoM()  { probe("websafari", "Wu8xNx4njoM") }
    func testProbe_websafari__y9R5a76HPbU()  { probe("websafari", "y9R5a76HPbU") }
    func testProbe_websafari__Dy9ki9Q5nXs()  { probe("websafari", "Dy9ki9Q5nXs") }
    func testProbe_websafari__jNQXAC9IVRw()  { probe("websafari", "jNQXAC9IVRw") }

    // MARK: - mweb

    func testProbe_mweb__dQw4w9WgXcQ()  { probe("mweb", "dQw4w9WgXcQ") }
    func testProbe_mweb__9bZkp7q19f0()  { probe("mweb", "9bZkp7q19f0") }
    func testProbe_mweb__LSMQ3U1Thzw()  { probe("mweb", "LSMQ3U1Thzw") }
    func testProbe_mweb__v2ZtAi2rDzA()  { probe("mweb", "v2ZtAi2rDzA") }
    func testProbe_mweb__Wu8xNx4njoM()  { probe("mweb", "Wu8xNx4njoM") }
    func testProbe_mweb__y9R5a76HPbU()  { probe("mweb", "y9R5a76HPbU") }
    func testProbe_mweb__Dy9ki9Q5nXs()  { probe("mweb", "Dy9ki9Q5nXs") }
    func testProbe_mweb__jNQXAC9IVRw()  { probe("mweb", "jNQXAC9IVRw") }

    // MARK: - android

    func testProbe_android__dQw4w9WgXcQ()  { probe("android", "dQw4w9WgXcQ") }
    func testProbe_android__9bZkp7q19f0()  { probe("android", "9bZkp7q19f0") }
    func testProbe_android__LSMQ3U1Thzw()  { probe("android", "LSMQ3U1Thzw") }
    func testProbe_android__v2ZtAi2rDzA()  { probe("android", "v2ZtAi2rDzA") }
    func testProbe_android__Wu8xNx4njoM()  { probe("android", "Wu8xNx4njoM") }
    func testProbe_android__y9R5a76HPbU()  { probe("android", "y9R5a76HPbU") }
    func testProbe_android__Dy9ki9Q5nXs()  { probe("android", "Dy9ki9Q5nXs") }
    func testProbe_android__jNQXAC9IVRw()  { probe("android", "jNQXAC9IVRw") }

    // MARK: - android-vr

    func testProbe_androidvr__dQw4w9WgXcQ()  { probe("android-vr", "dQw4w9WgXcQ") }
    func testProbe_androidvr__9bZkp7q19f0()  { probe("android-vr", "9bZkp7q19f0") }
    func testProbe_androidvr__LSMQ3U1Thzw()  { probe("android-vr", "LSMQ3U1Thzw") }
    func testProbe_androidvr__v2ZtAi2rDzA()  { probe("android-vr", "v2ZtAi2rDzA") }
    func testProbe_androidvr__Wu8xNx4njoM()  { probe("android-vr", "Wu8xNx4njoM") }
    func testProbe_androidvr__y9R5a76HPbU()  { probe("android-vr", "y9R5a76HPbU") }
    func testProbe_androidvr__Dy9ki9Q5nXs()  { probe("android-vr", "Dy9ki9Q5nXs") }
    func testProbe_androidvr__jNQXAC9IVRw()  { probe("android-vr", "jNQXAC9IVRw") }

    // MARK: - web-creator

    func testProbe_webcreator__dQw4w9WgXcQ()  { probe("web-creator", "dQw4w9WgXcQ", requiresAuth: true) }
    func testProbe_webcreator__9bZkp7q19f0()  { probe("web-creator", "9bZkp7q19f0", requiresAuth: true) }
    func testProbe_webcreator__LSMQ3U1Thzw()  { probe("web-creator", "LSMQ3U1Thzw", requiresAuth: true) }
    func testProbe_webcreator__v2ZtAi2rDzA()  { probe("web-creator", "v2ZtAi2rDzA", requiresAuth: true) }
    func testProbe_webcreator__Wu8xNx4njoM()  { probe("web-creator", "Wu8xNx4njoM", requiresAuth: true) }
    func testProbe_webcreator__y9R5a76HPbU()  { probe("web-creator", "y9R5a76HPbU", requiresAuth: true) }
    func testProbe_webcreator__Dy9ki9Q5nXs()  { probe("web-creator", "Dy9ki9Q5nXs", requiresAuth: true) }
    func testProbe_webcreator__jNQXAC9IVRw()  { probe("web-creator", "jNQXAC9IVRw", requiresAuth: true) }

    // MARK: - web-auth

    func testProbe_webauth__dQw4w9WgXcQ()  { probe("web-auth", "dQw4w9WgXcQ", requiresAuth: true) }
    func testProbe_webauth__9bZkp7q19f0()  { probe("web-auth", "9bZkp7q19f0", requiresAuth: true) }
    func testProbe_webauth__LSMQ3U1Thzw()  { probe("web-auth", "LSMQ3U1Thzw", requiresAuth: true) }
    func testProbe_webauth__v2ZtAi2rDzA()  { probe("web-auth", "v2ZtAi2rDzA", requiresAuth: true) }
    func testProbe_webauth__Wu8xNx4njoM()  { probe("web-auth", "Wu8xNx4njoM", requiresAuth: true) }
    func testProbe_webauth__y9R5a76HPbU()  { probe("web-auth", "y9R5a76HPbU", requiresAuth: true) }
    func testProbe_webauth__Dy9ki9Q5nXs()  { probe("web-auth", "Dy9ki9Q5nXs", requiresAuth: true) }
    func testProbe_webauth__jNQXAC9IVRw()  { probe("web-auth", "jNQXAC9IVRw", requiresAuth: true) }

    // MARK: - wkwebview-hls

    func testProbe_wkwebviewhls__dQw4w9WgXcQ()  { probe("wkwebview-hls", "dQw4w9WgXcQ") }
    func testProbe_wkwebviewhls__9bZkp7q19f0()  { probe("wkwebview-hls", "9bZkp7q19f0") }
    func testProbe_wkwebviewhls__LSMQ3U1Thzw()  { probe("wkwebview-hls", "LSMQ3U1Thzw") }
    func testProbe_wkwebviewhls__v2ZtAi2rDzA()  { probe("wkwebview-hls", "v2ZtAi2rDzA") }
    func testProbe_wkwebviewhls__Wu8xNx4njoM()  { probe("wkwebview-hls", "Wu8xNx4njoM") }
    func testProbe_wkwebviewhls__y9R5a76HPbU()  { probe("wkwebview-hls", "y9R5a76HPbU") }
    func testProbe_wkwebviewhls__Dy9ki9Q5nXs()  { probe("wkwebview-hls", "Dy9ki9Q5nXs") }
    func testProbe_wkwebviewhls__jNQXAC9IVRw()  { probe("wkwebview-hls", "jNQXAC9IVRw") }
}

#endif
