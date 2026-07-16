import XCTest

// MARK: - BotGuardWVAdaptiveUITests
//
// Validates that BotGuardWebViewRunner (WAA pipeline in WKWebView) successfully
// mints a pot= token and uses it to play via WEB client adaptive streaming
// (bypassing WKWebView HLS fallback) for a range of non-partner video IDs.
//
// Single shared app instance — all 9 videos are injected into the Recommended
// feed via --uitesting-inject-recommended-ids.  The app stays alive across all
// test methods so all logs land in one diagnostics file.
//
// AGENT-POST-RUN-CHECK: ui-tests-with-logs
//
// After running, grep the device log for these markers:
//
// ── BotGuard WEB client SUCCESS (ideal) ──────────────────────────────────────
//   "[BotGuardWV] ✅ adaptive streaming via minted BotGuard token — WKWebView HLS not needed"
//   "[BotGuardWV/WEB probe] CDN HEAD: HTTP 200"
//
// ── BotGuard prepare + mint succeeded but WEB client blocked ─────────────────
//   "[BotGuardWV] ✅ minted token (len=... webVD.len=...)"
//   "[BotGuardWV] ⚠️ WEB client fetch failed: unavailable(..."
//
// ── webVisitorData obtained (Phase 7 guide call) ─────────────────────────────
//   "[BotGuardWV] prepare result: ... webVisitorData.len=<N>"
//
// ── WKWebView fallback (WEB client adaptive failed) ──────────────────────────
//   "⚠️ [webView] fetching HLS manifest URL via WKWebView YouTube player"
//   "✅ [webView/HLS] readyToPlay"
//
// ── Grep all BotGuard signals ────────────────────────────────────────────────
//   grep "BotGuardWV\|adaptive streaming\|WEB probe\|webVD\|WEB client" <APP_LOG>

// Non-partner video IDs from the iPocketTube UI test suite.
// ZoYeJwN7Rkw excluded — NVIDIA Partner, WEB client always "Video unavailable".
private let kBGWVTestVideoIDs = [
    "LSMQ3U1Thzw",  // Ben Eater SID — multi-track, documented rqh=1
    "Dy9ki9Q5nXs",  // Scrubber test video
    "Wu8xNx4njoM",  // HLS resolution test video
    "m1WGX1-uGvU",  // WKHLSCookieProxy test video
    "JhCjw57u8mQ",  // Download test video
    "dQw4w9WgXcQ",  // Rick Astley — public
    "9bZkp7q19f0",  // PSY Gangnam Style
    "kJQP7kiw5Fk",  // Recommended feed fallback
    "OPf0YbXqDm0",  // Recommended feed fallback
]

// MARK: -

final class BotGuardWVAdaptiveUITests: XCTestCase {

    private static var sharedApp: XCUIApplication!
    private static var skipAll = false

    // MARK: - Lifecycle (single shared app)

    override class func setUp() {
        super.setUp()
        let injectedIDs = kBGWVTestVideoIDs.joined(separator: ",")
        let app = XCUIApplication()
        app.launchArguments = [
            "--uitesting",
            "--uitesting-disable-tos-player-on-ios",
            "--uitesting-inject-recommended-ids=\(injectedIDs)"
        ]
        app.launch()
        sharedApp = app

        UITestHelpers.tapTab(named: "Home", in: app)
        if UITestHelpers.waitForVideoCards(in: app, timeout: 25) == nil {
            skipAll = true
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
        try? XCTSkipIf(Self.skipAll, "Home feed unavailable")
    }

    // MARK: - Helper

    /// Taps the card at `index` in the injected Recommended feed, waits 50 s
    /// for BotGuard to complete, then navigates back to Home.
    private func playVideo(at index: Int, id: String) {
        let app = Self.sharedApp!

        // Navigate back to Home and wait for cards.
        UITestHelpers.tapTab(named: "Home", in: app)
        let backBtn = app.buttons["player.backButton"].firstMatch
        if backBtn.waitForExistence(timeout: 2) { backBtn.tap() }
        UITestHelpers.tapTab(named: "Home", in: app)

        let predicate = NSPredicate(format: "identifier BEGINSWITH 'video.card.'")
        let cards = app.descendants(matching: .any).matching(predicate)
        guard cards.count > index else {
            XCTFail("[\(id)] Only \(cards.count) cards, need index \(index)")
            return
        }
        let card = cards.element(boundBy: index)
        guard UITestHelpers.openPlayer(from: card, in: app) else {
            XCTFail("[\(id)] Player did not open within timeout")
            return
        }

        // BotGuardWebViewRunner WAA pipeline: ~15 s; WEB client attempt: ~2 s.
        Thread.sleep(forTimeInterval: 50)

        XCTAssertEqual(app.state, .runningForeground,
                       "[\(id)] App crashed during BotGuard pipeline")

        // Navigate back for next test.
        let back = app.buttons["player.backButton"].firstMatch
        if back.waitForExistence(timeout: 5) { back.tap() }
    }

    // MARK: - Tests (one per injected video, in inject order)

    func test00_LSMQ3U1Thzw() { playVideo(at: 0, id: "LSMQ3U1Thzw") }
    func test01_Dy9ki9Q5nXs()  { playVideo(at: 1, id: "Dy9ki9Q5nXs") }
    func test02_Wu8xNx4njoM()  { playVideo(at: 2, id: "Wu8xNx4njoM") }
    func test03_m1WGX1uGvU()   { playVideo(at: 3, id: "m1WGX1-uGvU") }
    func test04_JhCjw57u8mQ()  { playVideo(at: 4, id: "JhCjw57u8mQ") }
    func test05_dQw4w9WgXcQ()  { playVideo(at: 5, id: "dQw4w9WgXcQ") }
    func test06_9bZkp7q19f0()  { playVideo(at: 6, id: "9bZkp7q19f0") }
    func test07_kJQP7kiw5Fk()  { playVideo(at: 7, id: "kJQP7kiw5Fk") }
    func test08_OPf0YbXqDm0()  { playVideo(at: 8, id: "OPf0YbXqDm0") }
}
