import XCTest

// AGENT-POST-RUN-CHECK: ui-tests-with-logs
//
// After every run of this file, extract device/app logs and inspect.
//
// Log events to verify per video:
//   ✓ [load] load() called — id=<videoID>
//   ✓ cache HIT: playerInfo (skipping network)     — for every video AFTER the first
//   ✓ readyToPlay [<path>]                          — note the path (webView/HLS, Android/muxed, etc.)
//   ✓ [prefetch] ENQUEUE <nextID> priority=2        — prefetch for the following video
//
// Expected per-video paths (baseline):
//   v2ZtAi2rDzA  — cold start, rqh=1, pot= 403: BotGuardWV skips iOS/Android adaptive,
//                  falls through to WKWebView HLS (spc= authenticated).
//                  With fix: ~4–5 s (wkHLSTask parallel). Without: ~8 s (+3 s iOS timeout).
//   l7To2evwGKs  — hot (cached), rqh=1 via BotGuardWV fast path
//   dQw4w9WgXcQ  — hot (cached), webView/HLS or adaptive
//   jNQXAC9IVRw  — hot (cached), webView/HLS
//   fEvekF1zOKs  — hot (cached), rqh=1 BotGuard chain
//   Wu8xNx4njoM  — hot (cached)
//   LSMQ3U1Thzw  — hot (cached)
//
// RED FLAGS:
//   - "fetchPlayerInfo" appears for video 2+ → cache miss (prefetch too slow or evicted)
//   - priority=1 or priority=0 instead of priority=2 → queue inject not wiring correctly
//   - BotGuardWV timeout for cached video → expected for rqh=1 streams regardless of cache

/// Sequential per-video playback benchmark across all known test video IDs.
///
/// Injects all six known video IDs into the queue and advances through each
/// one, recording the wall-clock time from "tap Next" to "title changed".
/// The first video is timed from app launch.
///
/// Cache behaviour: each video's PlayerInfo is prefetched at `.immediate` (priority=2)
/// while the current video plays. By the time the user advances, the next video's
/// PlayerInfo should already be in `VideoPreloadCache`, giving a cache HIT on load().
///
/// Run via:
///   xcodebuild test -workspace AxrTube.xcworkspace -scheme iPocketTube \
///     -destination 'id=6CEE2FAC-7D50-4BD0-95E2-1361EDD7FAF6' \
///     -only-testing:iPocketTubeUITests/VideoPlaybackBenchmarkUITests \
///     -parallel-testing-enabled YES -maximum-parallel-testing-workers 5 \
///     -resultBundlePath /tmp/benchmark_results.xcresult 2>&1 | tee /tmp/benchmark_build.log
final class VideoPlaybackBenchmarkUITests: XCTestCase {

    /// All known stable video IDs, ordered so cache warms progressively:
    ///   - First: real-world worst-case video (2026-05-29 log.txt) — rqh=1, pot= 403,
    ///     all BotGuardWV adaptive paths fail, falls through to WKWebView HLS.
    ///     Measures cold start after the "WEB probe 403 → skip iOS/Android" fix.
    ///   - Second: rqh=1 real-world video from 2026-05-28 log — BotGuardWV fast path
    ///   - Next two mirror the existing NextVideoPrefetchUITests queue
    ///   - Last two are from HLSResolution and BotGuardLivePipeline test suites
    private static let allVideoIDs: [String] = [
        "v2ZtAi2rDzA",  // rqh=1, pot= 403 worst-case — measures WKWebView HLS cold path
        "l7To2evwGKs",  // Real-world rqh=1 video (log.txt 2026-05-28) — BotGuardWV fast path
        "dQw4w9WgXcQ",  // Rick Astley — stable, typical adaptive/HLS path
        "LSMQ3U1Thzw",  // BotGuard probe test video
    ]

    private var app: XCUIApplication!
    /// Shuffled on every setUp so each run has a different cold-start video.
    private var orderedVideoIDs: [String] = []

    override func setUpWithError() throws {
        continueAfterFailure = false
        orderedVideoIDs = Self.allVideoIDs.shuffled()
        app = XCUIApplication()
        app.launchArguments = [
            "--uitesting",
            "--uitesting-disable-tos-player-on-ios",
            "--uitesting-inject-queue-video-ids=\(orderedVideoIDs.joined(separator: ","))",
            "--uitesting-show-controls",
            "--uitesting-disable-sponsorblock",
        ]
        #if os(iOS)
        XCUIDevice.shared.orientation = .portrait
        #endif
        app.launch()
    }

    override func tearDownWithError() throws {
        app?.terminate()
        app = nil
    }

    // MARK: - Tests

    /// Advances through every queued video in sequence and records wall-clock
    /// time-to-title-change per video.
    ///
    /// "Time to title change" is the proxy for "time to first frame / readyToPlay":
    /// the player title label updates once the new video's metadata has loaded and
    /// the player has begun buffering.  The post-run log check confirms whether
    /// each advance was served from the prefetch cache or hit the network.
    func testSequentialPerVideoPlaybackTimes() throws {
        let videoIDs = orderedVideoIDs
        let playerTitle = app.staticTexts["player.titleLabel"].firstMatch

        // ── Video 0: cold start ───────────────────────────────────────────────
        // Allow 4 s after launch for BotGuardWebViewRunner to begin pre-warming
        // the WKWebView context (triggered by prefetchQueueVideo inside load()).
        // This simulates real-world usage where the home feed has already scrolled
        // and the pre-warm is in-flight before the user taps the video.
        // The cold timer starts AFTER the pause so it measures "time from pre-warm
        // start" rather than "time from zero".
        Thread.sleep(forTimeInterval: 4.0)
        let coldStart = Date()
        guard playerTitle.waitForExistence(timeout: 35) else {
            try captureAndSkip("First video did not load — network unavailable or video inaccessible", in: app)
        }
        let coldElapsed = Date().timeIntervalSince(coldStart)
        var timings: [(id: String, elapsedSeconds: Double, hot: Bool)] = [
            (videoIDs[0], coldElapsed, false),
        ]
        print("[benchmark] \(videoIDs[0])  cold  \(String(format: "%.2f", coldElapsed))s")

        // ── Videos 1…N: advance through queue, time each ─────────────────────
        for index in 1..<videoIDs.count {
            let videoID = videoIDs[index]

            XCTContext.runActivity(named: "Advance to video \(index): \(videoID)") { _ in
                // Capture current title so we can detect when it changes.
                let prevLabel = playerTitle.exists ? playerTitle.label : ""

                // Poll for nextBtn to be enabled. Controls auto-hide, so tap
                // the centre periodically to keep them visible.
                let nextButton = app.buttons["player.nextBtn"].firstMatch
                var nextReady = false
                let btnDeadline = Date().addingTimeInterval(90)
                while Date() < btnDeadline {
                    app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                    Thread.sleep(forTimeInterval: 1.0)
                    if nextButton.waitForExistence(timeout: 2), nextButton.isEnabled {
                        nextReady = true
                        break
                    }
                }
                guard nextReady else {
                    XCTFail("player.nextBtn not enabled before video \(videoID) (index \(index)) within 90 s")
                    return
                }

                // ── Start timing ──────────────────────────────────────────────
                let start = Date()
                nextButton.tap()

                // Poll until the title label changes to something new.
                var titleChanged = false
                let loadDeadline = Date().addingTimeInterval(60)
                var lastTapTime = Date()

                while Date() < loadDeadline {
                    Thread.sleep(forTimeInterval: 0.5)

                    // Keep controls alive every ~3 s.
                    if Date().timeIntervalSince(lastTapTime) >= 3 {
                        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                        lastTapTime = Date()
                    }

                    let currentLabel = playerTitle.exists ? playerTitle.label : ""
                    if !currentLabel.isEmpty, currentLabel != prevLabel {
                        titleChanged = true
                        break
                    }
                }

                let elapsed = Date().timeIntervalSince(start)

                guard titleChanged else {
                    XCTFail("Title did not change for video \(videoID) within 60 s (elapsed: \(String(format: "%.1f", elapsed))s, prevLabel: '\(prevLabel)')")
                    return
                }

                timings.append((videoID, elapsed, true))
                print("[benchmark] \(videoID)  hot   \(String(format: "%.2f", elapsed))s")
            }
        }

        // ── Report ────────────────────────────────────────────────────────────
        let separator = String(repeating: "-", count: 44)
        var lines = [separator]
        lines.append("videoID        type  elapsed")
        lines.append(separator)
        for t in timings {
            let idPadded = t.id.padding(toLength: 14, withPad: " ", startingAt: 0)
            let typePadded = (t.hot ? "hot" : "cold").padding(toLength: 4, withPad: " ", startingAt: 0)
            lines.append("\(idPadded)  \(typePadded)  \(String(format: "%.2f", t.elapsedSeconds))s")
        }
        lines.append(separator)
        let report = lines.joined(separator: "\n")
        print("[benchmark] results:\n\(report)")

        let attachment = XCTAttachment(string: report)
        attachment.name = "Per-video playback times"
        attachment.lifetime = .keepAlways
        add(attachment)

        XCTAssertEqual(timings.count, videoIDs.count,
                       "Expected \(videoIDs.count) timing entries, got \(timings.count)")
    }
}
