#if !os(tvOS)
import XCTest

// AGENT-POST-RUN-CHECK: ui-tests-with-logs
//
// After every run of this file, extract device/app logs and inspect.
//
// Log events to verify per video:
//   ✓ [load] load() called — id=<videoID>
//   ✓ cache HIT: playerInfo (skipping network)     — for every video AFTER the first
//   ✓ readyToPlay [<path>]                          — note the path (webView/HLS, muxed, etc.)
//   ✓ [prefetch] ENQUEUE <nextID> priority=2        — prefetch for the following video
//
// RED FLAGS:
//   - "Android[N]/muxed/muxed" in readyToPlay → nSolver race (fixNSolver not active, or needs rebuild)
//   - "nSolver=nil" in Path B → nSolver race condition
//   - CFHTTP -12660 lines → 403 on HLS segments (nSolver missing)
//   - "fetchPlayerInfo" for video 2+ → cache miss (prefetch too slow or evicted)
//   - Quality picker shows only 360p → muxed fallback triggered
//
// Run via:
//   xcodebuild test \
//     -workspace iPocketTube.xcworkspace -scheme iPocketTube \
//     -destination "platform=macOS" \
//     -only-testing:iPocketTubeUITests/MacVideoPlaybackBenchmarkUITests \
//     -parallel-testing-enabled NO \
//     -resultBundlePath /tmp/mac-benchmark.xcresult

/// Sequential per-video playback benchmark for macOS.
///
/// Mirrors `VideoPlaybackBenchmarkUITests` (iOS) adapted for macOS:
///   - No orientation setup (macOS is always landscape/windowed)
///   - Mouse clicks via `.click()` instead of `.tap()`
///   - Controls kept visible via `--uitesting-show-controls`
///   - Timing: wall-clock from nextBtn click → player.titleLabel text changes
///
/// The first video is injected via `--uitesting-inject-queue-video-ids` and
/// opened automatically by `consumeQueueInjectFromLaunchArgs()` in AppEntry.
final class MacVideoPlaybackBenchmarkUITests: XCTestCase {

    private static let allVideoIDs: [String] = [
        "y9R5a76HPbU",  // nSolver regression video — must NOT be Android[N]/muxed
        "v2ZtAi2rDzA",  // rqh=1 worst-case — WKWebView HLS cold path
        "dQw4w9WgXcQ",  // Rick Astley — stable adaptive/HLS path
        "LSMQ3U1Thzw",  // BotGuard probe test video
    ]

    private var app: XCUIApplication!
    private var orderedVideoIDs: [String] = []

    override func setUpWithError() throws {
        continueAfterFailure = false
        orderedVideoIDs = Self.allVideoIDs.shuffled()
        app = XCUIApplication()
        app.launchArguments = [
            "--uitesting",
            "--uitesting-inject-queue-video-ids=\(orderedVideoIDs.joined(separator: ","))",
            "--uitesting-show-controls",
            "--uitesting-disable-sponsorblock",
        ]
        // On macOS, SwiftUI WindowGroup won't create a window if the OS has saved an
        // empty window state (e.g. previous test terminated without any open windows).
        // Fix: delete the saved state directory so the app launches as if new, and also
        // pass the NSUserDefaults key as a launch arg so SwiftUI skips restoration.
        #if os(macOS)
        let savedState = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Saved Application State/com.void.ipockettube.app.savedState")
        try? FileManager.default.removeItem(at: savedState)
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        #endif
        app.launch()
        // On macOS, give the window time to appear.
        #if os(macOS)
        _ = app.windows.firstMatch.waitForExistence(timeout: 10)
        #endif
    }

    override func tearDownWithError() throws {
        app?.terminate()
        app = nil
    }

    // MARK: - Tests

    func testSequentialPerVideoPlaybackTimes() throws {
        let videoIDs = orderedVideoIDs
        let playerTitle = app.staticTexts["player.titleLabel"].firstMatch

        // ── Video 0: cold start ───────────────────────────────────────────────
        // Allow 4 s after launch for BotGuardWebViewRunner to begin pre-warming.
        Thread.sleep(forTimeInterval: 4.0)
        // Start cold timer immediately after the pre-warm window.
        // The queue-inject sets video.title = videoID as a placeholder so the element
        // exists immediately in the AX tree. We poll until the real title arrives from
        // the /player API response — that's the signal that playerInfo is fetched and
        // the video is ready to play. Starting here (not after waitForExistence) ensures
        // we capture the full cold startup time even when the video loads quickly.
        let coldStart = Date()
        let coldVideoID = videoIDs[0]
        let coldTitleDeadline = Date().addingTimeInterval(60)
        var coldReady = false
        while Date() < coldTitleDeadline {
            if playerTitle.waitForExistence(timeout: 1) {
                let t = titleText(of: playerTitle)
                if !t.isEmpty, t != coldVideoID {
                    coldReady = true
                    break
                }
            }
            Thread.sleep(forTimeInterval: 0.4)
        }
        guard coldReady else {
            try captureAndSkip(
                "First video did not load — network unavailable or video inaccessible",
                in: app
            )
        }
        let coldElapsed = Date().timeIntervalSince(coldStart)
        var timings: [(id: String, elapsed: Double, hot: Bool)] = [
            (videoIDs[0], coldElapsed, false),
        ]
        print("[benchmark-mac] \(videoIDs[0])  cold  \(String(format: "%.2f", coldElapsed))s")

        // ── Videos 1…N: tap nextBtn, time each ───────────────────────────────
        for index in 1..<videoIDs.count {
            let videoID = videoIDs[index]

            XCTContext.runActivity(named: "Advance to video \(index): \(videoID)") { _ in
                let prevLabel = titleText(of: playerTitle)

                // Poll for nextBtn to be enabled. On macOS, controls are persistent
                // (no auto-hide) when --uitesting-show-controls is passed.
                let nextButton = app.buttons["player.nextBtn"].firstMatch
                var nextReady = false
                let btnDeadline = Date().addingTimeInterval(90)
                while Date() < btnDeadline {
                    // On iOS, tap the screen to keep controls visible.
                    // On macOS, controls are persistent (via --uitesting-show-controls)
                    // and tapping the window outside the sheet would dismiss it.
                    #if !os(macOS)
                    app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                    #endif
                    Thread.sleep(forTimeInterval: 0.8)
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
                #if os(macOS)
                nextButton.click()
                #else
                nextButton.tap()
                #endif

                // Poll until the title label changes to something new.
                var titleChanged = false
                let loadDeadline = Date().addingTimeInterval(90)
                #if !os(macOS)
                var lastClickTime = Date()
                #endif
                while Date() < loadDeadline {
                    Thread.sleep(forTimeInterval: 0.5)

                    // Keep controls visible on iOS (macOS controls are persistent via --uitesting-show-controls;
                    // tapping the window on macOS would dismiss the sheet over the NavigationSplitView).
                    #if !os(macOS)
                    if Date().timeIntervalSince(lastClickTime) >= 3 {
                        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                        lastClickTime = Date()
                    }
                    #endif

                    let currentLabel = titleText(of: playerTitle)
                    // Skip the ID placeholder that load() sets synchronously before
                    // the network fetch completes — only stop when the real title arrives.
                    if !currentLabel.isEmpty, currentLabel != prevLabel, currentLabel != videoID {
                        titleChanged = true
                        break
                    }
                }

                let elapsed = Date().timeIntervalSince(start)

                guard titleChanged else {
                    XCTFail("Title did not change for video \(videoID) within 90 s (prevLabel: '\(prevLabel)')")
                    return
                }

                timings.append((videoID, elapsed, true))
                print("[benchmark-mac] \(videoID)  hot   \(String(format: "%.2f", elapsed))s")
            }
        }

        // ── Report ────────────────────────────────────────────────────────────
        let separator = String(repeating: "-", count: 44)
        var lines = [separator, "videoID        type  elapsed", separator]
        for t in timings {
            let idPad  = t.id.padding(toLength: 14, withPad: " ", startingAt: 0)
            let typPad = (t.hot ? "hot" : "cold").padding(toLength: 4, withPad: " ", startingAt: 0)
            lines.append("\(idPad)  \(typPad)  \(String(format: "%.2f", t.elapsed))s")
        }
        lines.append(separator)
        let report = lines.joined(separator: "\n")
        print("[benchmark-mac] results:\n\(report)")

        let attachment = XCTAttachment(string: report)
        attachment.name = "macOS per-video playback times"
        attachment.lifetime = .keepAlways
        add(attachment)

        XCTAssertEqual(timings.count, videoIDs.count,
                       "Expected \(videoIDs.count) timing entries, got \(timings.count)")
    }

    // MARK: - Private helpers

    /// Returns the title text from the player.titleLabel element.
    /// On macOS, XCUIElement.label maps to AXDescription (often empty for opacity-0 StaticText).
    /// The actual text content is in element.value (AXValue), so we prefer that on macOS.
    private func titleText(of element: XCUIElement) -> String {
        guard element.exists else { return "" }
        #if os(macOS)
        return (element.value as? String) ?? element.label
        #else
        return element.label
        #endif
    }

    private func captureAndSkip(_ message: String, in app: XCUIApplication) throws -> Never {
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "skip-screenshot"
        attachment.lifetime = .keepAlways
        add(attachment)
        throw XCTSkip(message)
    }
}
#endif
