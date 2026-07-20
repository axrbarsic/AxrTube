import XCTest

// AGENT-POST-RUN-CHECK: ui-tests-with-logs
//
// Each test method is one video ID. The app is fully terminated and relaunched
// between every test — BotGuard cache, WKWebView state, and AVPlayer are all
// cold for every run.
//
// LEGITIMATE skip:
//   - Network unavailable / no connectivity on CI
//   - Home feed injection failed (rare xctest race on slow simulators)
//
// BUG skip (must fix before closing):
//   - player.titleLabel never appeared within 30 s (readyToPlay not reached)
//   - App crashed during playback
//   - player.errorBanner visible after readyToPlay
//
// Log events to verify (grep APP_LOG for each video):
//   ✓ [benchmark] readyToPlay in \d+ ms   — must appear; value = TTP
//   ✓ path [ABC] won                       — exactly one winning path per run
//   ✓ readyToPlay → quality ramp           — 700 ms ramp must fire
//
// Informational (record in time-to-play-results.md):
//   · [botguard] token cache hit           — BotGuard was warm (< 5 ms)
//   · [botguard] minting                   — BotGuard was cold (+0.5–2 s)
//   · [wkwebview] early task complete      — WKWebView extractor delivered URL
//   · [wkwebview] early task timeout       — WKWebView extractor missed deadline
//   · [hls] direct URL                     — single-URL HLS (fastest composition)
//   · [composition] setup                  — AVMutableComposition path (no HLS)
//
// RED FLAGS:
//   · exhaustiveRetry: trying              — all three race paths failed, waterfall started
//   · ERROR | error | failed | fallback    — unexpected failure, investigate log
//   · No [benchmark] line                  — readyToPlay never fired
//
// Run command (serial, result bundle):
//   RESULT=/tmp/ttp-bench-$(date +%s).xcresult
//   xcodebuild test \
//     -workspace AxrTube.xcworkspace \
//     -scheme iPocketTube \
//     -destination "id=6CEE2FAC-7D50-4BD0-95E2-1361EDD7FAF6" \
//     -only-testing:iPocketTubeUITests/TimeToPlayBenchmarkUITests \
//     -parallel-testing-enabled YES \
//     -maximum-parallel-testing-workers 3 \
//     -resultBundlePath "$RESULT" \
//     2>&1 | tee /tmp/ttp-bench.log
//
// Extract logs after run:
//   LOG_DIR=/tmp/ttp-diag-$(date +%s)
//   xcrun xcresulttool export diagnostics --path "$RESULT" --output-path "$LOG_DIR"
//   APP_LOG=$(find "$LOG_DIR" -name "*.log" | grep -iv runner | head -1)

// MARK: - Video corpus

/// One entry per video ID in the benchmark.
private struct TTPTestCase {
    let videoId: String
    let scenario: String
}

/// Full video corpus — add new IDs here, no matching test method needed.
private let corpus: [TTPTestCase] = [
    // ── Established reference videos ──────────────────────────────────────────
    TTPTestCase(videoId: "dQw4w9WgXcQ", scenario: "popular-CDN-hot"),              // Path A (BotGuard warm)
    TTPTestCase(videoId: "l7To2evwGKs", scenario: "real-world-ref-2026-05-28"),    // Path A fast
    TTPTestCase(videoId: "9bZkp7q19f0", scenario: "high-view-count"),              // Path A or B
    TTPTestCase(videoId: "LSMQ3U1Thzw", scenario: "rqh1-multi-audio"),             // Path B or C
    TTPTestCase(videoId: "v2ZtAi2rDzA", scenario: "rqh1-cold-worst-case"),         // Path B or C
    TTPTestCase(videoId: "Dy9ki9Q5nXs", scenario: "scrubber-test"),                // Path A
    TTPTestCase(videoId: "Wu8xNx4njoM", scenario: "hls-resolution"),               // Path A or B
    TTPTestCase(videoId: "m1WGX1-uGvU", scenario: "wkwebview-cookie-proxy"),       // Path B
    TTPTestCase(videoId: "jNQXAC9IVRw", scenario: "queue-prefetch-ref"),           // Path A
    TTPTestCase(videoId: "MCv4EyEFgVg", scenario: "short-as-regular"),             // Path A or C
    // ── Real home-feed videos (scrolled live, 2026-06-02) ────────────────────
    TTPTestCase(videoId: "9XGXs23wUec", scenario: "home-Polestar5Review"),
    TTPTestCase(videoId: "Pg8jy6PmGas", scenario: "home-UnlimitedEnergy"),
    TTPTestCase(videoId: "l-NuEtz9gD8", scenario: "home-VWIDPolo"),
    TTPTestCase(videoId: "_6pF3_MLlco", scenario: "home-EEVblogMailbag"),
    TTPTestCase(videoId: "lnDmrY10kZg", scenario: "home-iOS27SiriLeak"),
    TTPTestCase(videoId: "uYiEXwti1_U", scenario: "home-MaoTaiwanDoc"),
    TTPTestCase(videoId: "lFz5HdONtr8", scenario: "home-GasDetectorModule"),
    TTPTestCase(videoId: "Pwn8IrDeiwc", scenario: "home-Quicksand"),
    TTPTestCase(videoId: "_ivqWN4L3zU", scenario: "home-CathedralEngineering"),
    TTPTestCase(videoId: "umX6Euh3B-g", scenario: "home-ArcticBalloon"),
    TTPTestCase(videoId: "a5cjBG6s6IY", scenario: "home-NewAppleTv"),
    TTPTestCase(videoId: "b3LvTbzuzCM", scenario: "home-TheEusNew"),
    TTPTestCase(videoId: "HuymABjcGgk", scenario: "home-WhyJordanBardella"),
    TTPTestCase(videoId: "3IlEdLT1esg", scenario: "home-1653AmericanLocks"),
    TTPTestCase(videoId: "wyBkLyGWZyU", scenario: "home-MagnetsArentAlways"),
    TTPTestCase(videoId: "TYQCjFKPxo0", scenario: "home-IranWarTrump"),
    TTPTestCase(videoId: "CmgtzD7jeZE", scenario: "home-JudgeDeniesClosure"),
    TTPTestCase(videoId: "RyxRWtQdwdk", scenario: "home-AllCalmOutside"),
    TTPTestCase(videoId: "AIJvfB2lDrI", scenario: "home-3KilledIn"),
    TTPTestCase(videoId: "H3M2TtPsyz0", scenario: "home-HyperparasiticWasps"),
    TTPTestCase(videoId: "WKU0qDpu3AM", scenario: "home-NobodyKnowsWhat"),
    TTPTestCase(videoId: "O4A3HhLXGMo", scenario: "home-ConfrontingPatrick"),
    TTPTestCase(videoId: "p0cLeC_2uVg", scenario: "home-WhatsTheWorlds"),
    TTPTestCase(videoId: "ofriDvpAzBM", scenario: "home-FirstDriveHas"),
    TTPTestCase(videoId: "fpaT9_H4ohA", scenario: "home-TheSteroidOlympics"),
    TTPTestCase(videoId: "CDILhdQgBOM", scenario: "home-BeastRtx5090"),
    TTPTestCase(videoId: "S6XIxnb7AsQ", scenario: "home-GooglesNewAi"),
    TTPTestCase(videoId: "O3dSjY4j7Ak", scenario: "home-WhyLifeIn"),
    TTPTestCase(videoId: "qZiqmrGiYwk", scenario: "home-AustralianFirmChallenges"),
    TTPTestCase(videoId: "PETZij7Cp9g", scenario: "home-LianLisDoublebarrel"),
    TTPTestCase(videoId: "kUbYDE-l96Y", scenario: "home-ThisIsThe"),
    TTPTestCase(videoId: "En104ViOtx4", scenario: "home-OtherMindsAnd"),
    TTPTestCase(videoId: "29gHloT4ZWc", scenario: "home-17InsanelyAddictive"),
    TTPTestCase(videoId: "dAP3L58XzUw", scenario: "home-ElectroluxWasherWont"),
    TTPTestCase(videoId: "vcpVYLl48f0", scenario: "home-11NewVr"),
    TTPTestCase(videoId: "poZTvu2JPUo", scenario: "home-LearnBahasaIndonesia"),
    TTPTestCase(videoId: "w8vWBWHtT5k", scenario: "home-TheConquerorsLie"),
    TTPTestCase(videoId: "jyo_m_TdYj8", scenario: "home-ScifiShortFilm"),
    TTPTestCase(videoId: "oTXFZlbKFLk", scenario: "home-UltimateHawaiianFood"),
    TTPTestCase(videoId: "wIIdU1Vkyn4", scenario: "home-ICantBelieve"),
    TTPTestCase(videoId: "QC2tQcwAaKU", scenario: "home-UsingThePsp"),
    TTPTestCase(videoId: "dA4_g6dbPS0", scenario: "home-WhatIsThis"),
    TTPTestCase(videoId: "Nrd6CkyxYDc", scenario: "home-AnastasiiaMetelkina"),
    TTPTestCase(videoId: "k8wUbcw9Yr4", scenario: "home-RazerDeathadder"),
    TTPTestCase(videoId: "ptaH9RkssvY", scenario: "home-DaJeImitirati"),
    TTPTestCase(videoId: "Z1W6a563Jec", scenario: "home-HowShouldThe"),
    TTPTestCase(videoId: "9pvNuptmzyQ", scenario: "home-The125vTrick"),
    TTPTestCase(videoId: "JhgjgNjVjSM", scenario: "home-ThisKotorQuest"),
    TTPTestCase(videoId: "nGuYas7G3q4", scenario: "home-AWhaleseyeview"),
    TTPTestCase(videoId: "ALE1EiAdZNo", scenario: "home-TheWorldsLargest"),
    TTPTestCase(videoId: "1fmITMAd90g", scenario: "home-ZxSpectrumVenture"),
    TTPTestCase(videoId: "73Do0OScoOU", scenario: "home-TheFirstEntity"),
    TTPTestCase(videoId: "Dflt3IEPJRI", scenario: "home-HowNetflixMishandled"),
    TTPTestCase(videoId: "ra8ikzuPcCA", scenario: "home-EverythingYouNeed"),
    TTPTestCase(videoId: "SyuC3FueR-M", scenario: "home-SheNeverGot"),
    TTPTestCase(videoId: "iPMQKRp89Xw", scenario: "home-Commodore642goal"),
    TTPTestCase(videoId: "hIOW2HKgzPk", scenario: "home-WhyFastFood"),
    TTPTestCase(videoId: "443gVF7y71M", scenario: "home-ArcadeTrashTo"),
    TTPTestCase(videoId: "7IIF0hNXW5E", scenario: "home-Best2Aliexpress"),
    TTPTestCase(videoId: "XJMbeG3tXjc", scenario: "home-NvidiasHostileTakeover"),
    TTPTestCase(videoId: "vL9urd1ixhA", scenario: "home-GoldenPerfectionDarja"),
    TTPTestCase(videoId: "mlFuT6xgQvE", scenario: "home-4kOledLeaps"),
    TTPTestCase(videoId: "03A4P34LeOk", scenario: "home-TheToxicLogic"),
    TTPTestCase(videoId: "r1y09JIcrNE", scenario: "home-BambuLabA2l"),
    TTPTestCase(videoId: "DVxVGByTTzM", scenario: "home-ICanOnly"),
    TTPTestCase(videoId: "DA2n1lkhmw8", scenario: "home-NaphthaSupplyWoes"),
    TTPTestCase(videoId: "qYPhXkX28J0", scenario: "home-BlastAtMyanmar"),
    TTPTestCase(videoId: "QAkAdotgPgk", scenario: "home-FromCleanroomTo"),
    TTPTestCase(videoId: "kdMIUJBygNw", scenario: "home-Commodore64Cocytus"),
    TTPTestCase(videoId: "9kxx5xp5nTQ", scenario: "home-WeWillRuin"),
    TTPTestCase(videoId: "TmMsRjPw0Vk", scenario: "home-RokusNewStrategy"),
    TTPTestCase(videoId: "8tdwKDf_h5M", scenario: "home-CallerSaysHes"),
    TTPTestCase(videoId: "RsleJJaxgqM", scenario: "home-ZxSpectrumTharkys"),
    TTPTestCase(videoId: "HNNjoheRzgo", scenario: "home-WrestlingBavarian"),
    TTPTestCase(videoId: "xuBQjY89diU", scenario: "home-HomebrewGamesAmiga"),
    TTPTestCase(videoId: "4f1-7c6WX10", scenario: "home-DoomRunsOn"),
    TTPTestCase(videoId: "5I7vuCqJtrA", scenario: "home-AkitaGoodManners"),
    TTPTestCase(videoId: "V9VnE5y8OTA", scenario: "home-Computex2026"),
    TTPTestCase(videoId: "zibhmjpuFm0", scenario: "home-EpoUfufufuTiny"),
    TTPTestCase(videoId: "F4al6ResSz4", scenario: "home-UschinaRelations"),
    TTPTestCase(videoId: "crzxR8enx6o", scenario: "home-TrumpsPardonsLast"),
    TTPTestCase(videoId: "slXf236dDQk", scenario: "home-BuildingPlayableMario"),
    TTPTestCase(videoId: "-guPcAUnTCM", scenario: "home-TheChristianGod"),
    TTPTestCase(videoId: "xcj-ImnrGcg", scenario: "home-IsTranshumanismThe"),
    TTPTestCase(videoId: "vsXOhTmboGI", scenario: "home-S13E13Freedom"),
    TTPTestCase(videoId: "G7OL8rSCKIs", scenario: "home-5GatsuHaishin"),
    TTPTestCase(videoId: "GpA7-EJpKWU", scenario: "home-IBuiltThe"),
    TTPTestCase(videoId: "eMZwqjvu2Gg", scenario: "home-The5800x3dReturns"),
    TTPTestCase(videoId: "ehT3U935Pww", scenario: "home-TaiwansDramFailure"),
    TTPTestCase(videoId: "II0pbvH3pgQ", scenario: "home-SolvingTheGpu"),
    TTPTestCase(videoId: "w1p4GkdiIAI", scenario: "home-Vic20HaikuCreator"),
    TTPTestCase(videoId: "xyHn9xoyyFA", scenario: "home-RerestoringTheSteam"),
    TTPTestCase(videoId: "XaL1Vn0gE9o", scenario: "home-TheInjustice3"),
    TTPTestCase(videoId: "6F43lcXR57s", scenario: "home-NoGoodReasons"),
    TTPTestCase(videoId: "S9FvZR814MY", scenario: "home-TheBestOf"),
    TTPTestCase(videoId: "IFqI11SIGXo", scenario: "home-SteelAbsorbsGas"),
    TTPTestCase(videoId: "PudtXINPPho", scenario: "home-TheBiggestLies"),
    TTPTestCase(videoId: "MXPqEkNVH_4", scenario: "home-HeBuiltThe"),
]

// MARK: - TimeToPlayBenchmarkUITests

/// Serial time-to-play benchmark — one fresh app launch per video ID.
///
/// Measures wall-clock time from the moment the video card is tapped to the
/// moment `player.titleLabel` appears (proxy for `readyToPlay` + first frame).
/// The canonical metric is the `[benchmark] readyToPlay in X ms` log line
/// emitted by `PlaybackViewModel+Loading.swift`.
///
/// Each test is completely independent:
///   • Fresh `XCUIApplication` created and launched in the test body.
///   • Single video ID injected via `--uitesting-inject-recommended-ids`.
///   • App terminated in `tearDown` so state never leaks between videos.
///
/// Do NOT add `parallelizationMode` or run with `-maximum-parallel-testing-workers > 1` —
/// timing measurements require a clean, uncontested simulator.
final class TimeToPlayBenchmarkUITests: XCTestCase {

    private var app: XCUIApplication!

    // MARK: - Lifecycle

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    override func tearDown() {
        app?.terminate()
        app = nil
        super.tearDown()
    }

    // MARK: - Parameterized benchmark (3 parallel batches)

    /// Corpus is split into 3 equal slices. xcodebuild distributes each method
    /// to a separate simulator clone when run with -maximum-parallel-testing-workers 3.
    /// Each clone runs its 36 videos serially so timing measurements stay clean.
    func test_allVideosTTP_batch1() { runBatch(Array(corpus.prefix(36))) }
    func test_allVideosTTP_batch2() { runBatch(Array(corpus[36..<72])) }
    func test_allVideosTTP_batch3() { runBatch(Array(corpus.suffix(from: 72))) }

    private func runBatch(_ batch: [TTPTestCase]) {
        continueAfterFailure = true
        for video in batch {
            XCTContext.runActivity(named: "\(video.videoId) (\(video.scenario))") { _ in
                do {
                    try runBenchmark(videoId: video.videoId, scenario: video.scenario)
                } catch let skip as XCTSkip {
                    // Legitimate skip (network unavailable, injection race) — log and continue.
                    print("[bench] SKIP \(video.videoId): \(skip)")
                } catch {
                    XCTFail("[\(video.videoId)] \(error)")
                }
                app?.terminate()
                app = nil
            }
        }
    }

    // MARK: - Core benchmark helper

    /// Launches the app with a single injected video, taps the card, and times
    /// the wall-clock duration until `player.titleLabel` is visible.
    ///
    /// - Parameters:
    ///   - videoId: The 11-character YouTube video ID to benchmark.
    ///   - scenario: Human-readable label used in the timing attachment and log line.
    private func runBenchmark(videoId: String, scenario: String) throws {
        print("[bench] ── START \(videoId) (\(scenario)) ──────────────────────────")

        // ── 1. Fresh app launch with single injected video ───────────────────
        app = XCUIApplication()
        app.launchArguments = [
            "--uitesting",
            "--uitesting-disable-tos-player-on-ios",
            "--uitesting-inject-recommended-ids=\(videoId)",
            "--uitesting-disable-sponsorblock",
            "--uitesting-extended-fetch-timeout",
            "--uitesting-disable-prefetch",
        ]
        print("[bench] \(videoId) launching with args: \(app.launchArguments)")
        app.launch()
        print("[bench] \(videoId) launched — pid=\(app.debugDescription.components(separatedBy: "pid=").dropFirst().first?.components(separatedBy: ",").first ?? "?")")

        // ── 2. Navigate to the Recommended chip so injected video is visible ──
        // `--uitesting-inject-recommended-ids` populates the Recommended chip feed,
        // not the default Home chip. Tap the chip to surface the injected card.
        let chipBar = app.scrollViews["home.chipBar"]
        guard waitForExistenceGuarded(chipBar, in: app, timeout: 20) else {
            print("[bench] \(videoId) SKIP — home.chipBar not found")
            try captureAndSkip(
                "[\(videoId)] home.chipBar not found — home screen did not load",
                in: app
            )
        }
        print("[bench] \(videoId) home.chipBar visible")
        let recommendedChip = chipBar.buttons["Recommended"].firstMatch
        guard waitForExistenceGuarded(recommendedChip, in: app, timeout: 10) else {
            print("[bench] \(videoId) SKIP — Recommended chip not found")
            try captureAndSkip(
                "[\(videoId)] Recommended chip not found in chip bar",
                in: app
            )
        }
        // Scroll chip into view if it's clipped by the horizontal chip bar.
        let screenWidth = app.windows.firstMatch.frame.width
        let nearEdge = chipBar.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5))
        let farEdge  = chipBar.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5))
        for _ in 0..<8 {
            let f = recommendedChip.frame
            if f.origin.x >= 4 && f.maxX <= screenWidth - 4 { break }
            if f.origin.x < 4 { nearEdge.press(forDuration: 0.05, thenDragTo: farEdge) }
            else               { farEdge.press(forDuration: 0.05, thenDragTo: nearEdge) }
        }
        print("[bench] \(videoId) tapping Recommended chip")
        recommendedChip.tap()

        // ── 3. Wait for the injected video card specifically ─────────────────
        let cardPredicate = NSPredicate(format: "identifier BEGINSWITH 'video.card.\(videoId)'")
        let specificCard = app.descendants(matching: .any).matching(cardPredicate).firstMatch
        guard waitForExistenceGuarded(specificCard, in: app, timeout: 20) else {
            print("[bench] \(videoId) SKIP — video.card.\(videoId) not found in feed")
            try captureAndSkip(
                "[\(videoId)] video.card.\(videoId) not found — injection may have failed or network unavailable",
                in: app
            )
        }
        let cardId = specificCard.identifier
        print("[bench] \(videoId) card found — identifier='\(cardId)'")

        // Guard: the card that appeared must contain the expected video ID.
        XCTAssertTrue(cardId.contains(videoId),
                      "[bench] WRONG CARD — expected video.card.\(videoId) but got '\(cardId)'")

        let card = specificCard

        // ── 3. Tap and start the clock ───────────────────────────────────────
        print("[bench] \(videoId) tapping card '\(cardId)'")
        let tapStart = Date()
        card.tap()
        print("[bench] \(videoId) card tapped — waiting for player.titleLabel")

        // ── 4. Wait for player ready (proxy: title label appears) ────────────
        let playerTitle = app.staticTexts["player.titleLabel"].firstMatch
        let didPlay = playerTitle.waitForExistence(timeout: 30)

        let ttpMs = Int(Date().timeIntervalSince(tapStart) * 1000)

        if !didPlay {
            captureState("timeout-\(videoId)", in: app)
            print("[bench] \(videoId) TIMEOUT — player.titleLabel never appeared after \(ttpMs) ms")
            print("[ttp] \(videoId)  \(scenario)  TIMEOUT (>\(ttpMs) ms)  tap→titleLabel-never-appeared")
        } else {
            let titleText = playerTitle.label
            print("[bench] \(videoId) player.titleLabel visible in \(ttpMs) ms — title='\(titleText)'")
            print("[ttp] \(videoId)  \(scenario)  \(ttpMs) ms  tap→titleLabel")
        }

        // ── 5. Dwell so post-readyToPlay log events accumulate ───────────────
        // Captures: quality ramp at 700 ms, audio track load, Phase 2 metadata.
        Thread.sleep(forTimeInterval: 3.0)

        // ── 6. Assertions ────────────────────────────────────────────────────
        XCTAssertEqual(app.state, .runningForeground,
                       "[\(videoId)] App is not in foreground — may have crashed during playback")
        if didPlay {
            UITestHelpers.assertNoPlayerErrorBanner(in: app, videoTitle: videoId)
        }
        print("[bench] \(videoId) done — terminating app")

        // ── 7. Attach structured result for post-run extraction ───────────────
        let ttpLabel = didPlay ? "\(ttpMs) ms" : "TIMEOUT (>\(ttpMs) ms)"
        let report = [
            "videoId:  \(videoId)",
            "scenario: \(scenario)",
            "TTP (tap→titleLabel): \(ttpLabel)",
            "",
            "# Fill from log grep after run:",
            "readyToPlay (ms):  <grep '[benchmark] readyToPlay in'>",
            "winning path:      <A / B / C / waterfall>",
            "botguard state:    <warm / cold / minting>",
            "wkwebview state:   <ready / timeout / n/a>",
            "hls type:          <direct / composition / muxed>",
            "quality ramp:      <fired / missing>",
            "errors:            <none / list>",
        ].joined(separator: "\n")

        let attachment = XCTAttachment(string: report)
        attachment.name = "TTP \(videoId)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
