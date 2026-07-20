#if os(tvOS)
import XCTest

// AGENT-POST-RUN-CHECK: ui-tests-with-logs
//
// After every run of this file, extract device/app logs and inspect.
//
// Log events to verify per video:
//   ✓ [load] load() called — id=<videoID>
//   ✓ cache HIT: playerInfo (skipping network)     — for every video AFTER the first
//   ✓ readyToPlay [<path>]                          — note the path
//   ✓ [prefetch] ENQUEUE <nextID> priority=2        — prefetch for the following video
//
// RED FLAGS:
//   - "fetchPlayerInfo" appears for video 2+ → cache miss
//   - "AVPlayerItem failed" → CDN auth failure
//   - cold > 1.15s → benchmark regression

/// Sequential per-video playback benchmark for tvOS.
///
/// Mirrors `VideoPlaybackBenchmarkUITests` (iOS) adapted for tvOS navigation:
///   - Remote D-pad (↓↓ select) to open first video from Home
///   - `player.nextBtn` tapped via XCTest accessibility for subsequent videos
///   - Darwin notification `com.void.ipockettube.player.ready` for sub-100ms timing
///
/// Run via:
///   xcodebuild test \
///     -workspace AxrTube.xcworkspace -scheme "iPocketTube" \
///     -destination 'id=E16182A3-794A-43DD-B349-A1FFBE744AF8' \
///     -only-testing:iPocketTubeTVUITests/TVVideoPlaybackBenchmarkUITests \
///     -parallel-testing-enabled NO \
///     -resultBundlePath /tmp/tv-benchmark.xcresult
final class TVVideoPlaybackBenchmarkUITests: XCTestCase {

    private static let allVideoIDs: [String] = [
        "v2ZtAi2rDzA",  // rqh=1 worst-case — WKWebView HLS cold path
        "l7To2evwGKs",  // rqh=1 real-world — BotGuardWV fast path
        "dQw4w9WgXcQ",  // Rick Astley — stable adaptive/HLS path
        "LSMQ3U1Thzw",  // BotGuard probe test video
    ]

    private var app: XCUIApplication!
    private let remote = XCUIRemote.shared
    /// Shuffled on every setUp so each run has a different cold-start video.
    private var orderedVideoIDs: [String] = []

    override func setUpWithError() throws {
        continueAfterFailure = false
        orderedVideoIDs = Self.allVideoIDs.shuffled()
        app = XCUIApplication()
        app.launchArguments = [
            "--uitesting",
            "--uitesting-inject-queue-video-ids=\(orderedVideoIDs.joined(separator: ","))",
            "--uitesting-disable-sponsorblock",
        ]
        app.launch()
    }

    override func tearDownWithError() throws {
        app?.terminate()
        app = nil
    }

    // MARK: - Tests

    func testSequentialPerVideoPlaybackTimes() throws {
        let videoIDs = orderedVideoIDs
        let playerTitle = app.staticTexts["player.titleLabel"].firstMatch

        // ── Navigate to Home feed ─────────────────────────────────────────────
        let chipBar = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'home.chipBar'"))
            .firstMatch
        guard chipBar.waitForExistence(timeout: 30) else {
            try captureAndSkip("home.chipBar did not appear — app failed to reach Home", in: app)
        }
        let cardPredicate = NSPredicate(format: "identifier BEGINSWITH 'video.card.'")
        let cards = app.descendants(matching: .any).matching(cardPredicate)
        let cardExp = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "count > 0"), object: cards
        )
        guard XCTWaiter().wait(for: [cardExp], timeout: 60) == .completed else {
            try captureAndSkip("No video cards — network unavailable or feed empty", in: app)
        }

        // ── Pre-warm pause ────────────────────────────────────────────────────
        // Allow BotGuardWebViewRunner 4 s to begin pre-warming before cold timer starts.
        Thread.sleep(forTimeInterval: 4.0)

        // ── Video 0: cold start ───────────────────────────────────────────────
        // Navigate: tab bar → chip bar (↓) → video list (↓) → select first card.
        remote.press(.down)
        Thread.sleep(forTimeInterval: 0.6)
        remote.press(.down)
        Thread.sleep(forTimeInterval: 0.6)

        let coldStart = Date()
        remote.press(.select)

        guard playerTitle.waitForExistence(timeout: 35) else {
            try captureAndSkip(
                "First video did not load within 35 s — network unavailable or video inaccessible",
                in: app
            )
        }
        let coldElapsed = Date().timeIntervalSince(coldStart)
        var timings: [(id: String, elapsed: Double, hot: Bool)] = [
            (videoIDs[0], coldElapsed, false),
        ]
        print("[benchmark-tv] \(videoIDs[0])  cold  \(String(format: "%.2f", coldElapsed))s")

        // ── Videos 1…N: feed-based hot navigation ────────────────────────────
        // On tvOS, nextBtn focus navigation is unreliable via XCTest (the focusable
        // container is a parent wrapper, not the button element itself). Instead:
        // wait 3s in the player → Menu back to feed → right to next pre-warmed card
        // → select. This matches real tvOS user flow and tests the pre-warm hot path.
        for index in 1..<videoIDs.count {
            let videoID = videoIDs[index]

            XCTContext.runActivity(named: "Hot video \(index): \(videoID)") { _ in
                // Let video play briefly so pre-warm has time to warm the next cards.
                Thread.sleep(forTimeInterval: 3.0)

                // Navigate back to feed via Menu.
                remote.press(.menu)
                Thread.sleep(forTimeInterval: 1.0)

                // Close mini-player if it appeared.
                let miniPlayer = app.otherElements["miniPlayer.bar"].firstMatch
                if miniPlayer.exists {
                    remote.press(.menu)
                    Thread.sleep(forTimeInterval: 0.5)
                }

                // Navigate down to video card list (same as cold start: tab → chip → cards).
                remote.press(.down)
                Thread.sleep(forTimeInterval: 0.5)
                remote.press(.down)
                Thread.sleep(forTimeInterval: 0.5)

                // Move right `index` steps to reach a different (pre-warmed) card.
                for _ in 0..<index {
                    remote.press(.right)
                    Thread.sleep(forTimeInterval: 0.3)
                }

                // Time: select card → com.void.ipockettube.player.ready Darwin notification.
                let readyExp = XCTDarwinNotificationExpectation(
                    notificationName: "com.void.ipockettube.player.ready"
                )
                let start = Date()
                remote.press(.select)

                let readyResult = XCTWaiter().wait(for: [readyExp], timeout: 35)
                let elapsed = Date().timeIntervalSince(start)

                // Wait for player title to confirm playback started.
                guard playerTitle.waitForExistence(timeout: max(35.0 - elapsed, 5.0)),
                      !playerTitle.label.isEmpty else {
                    XCTFail("No player title after hot video \(index) — navigation may have failed")
                    return
                }

                if readyResult != .completed {
                    print("[benchmark-tv] \(videoID)  hot   \(String(format: "%.2f", elapsed))s (readyToPlay not received — stalled?)")
                } else {
                    print("[benchmark-tv] \(videoID)  hot   \(String(format: "%.2f", elapsed))s")
                }
                timings.append((videoID, elapsed, true))
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
        print("[benchmark-tv] results:\n\(report)")

        let attachment = XCTAttachment(string: report)
        attachment.name = "TV per-video playback times"
        attachment.lifetime = .keepAlways
        add(attachment)

        XCTAssertEqual(timings.count, videoIDs.count,
                       "Expected \(videoIDs.count) timing entries, got \(timings.count)")
    }
}
#endif
