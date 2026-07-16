#if os(tvOS)
import XCTest

// MARK: - TVShortsDownNavigationUITests
//
// Regression test: pressing DOWN from the Shorts row must reach the video grid.
//
// Navigation path (Home chip, Shorts visible):
//   tab-bar  →(↓1)→  chip-bar  →(↓2)→  shorts-row  →(↓3)→  video-grid
//
// Run:
//   xcodebuild test -workspace iPocketTube.xcworkspace -scheme "iPocketTube" \
//     -destination "id=<simulator-udid>" \
//     -only-testing:iPocketTubeTVUITests/TVShortsDownNavigationUITests

final class TVShortsDownNavigationUITests: XCTestCase {

    private var app: XCUIApplication!
    private let remote = XCUIRemote.shared

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    override func tearDownWithError() throws { app = nil }

    // MARK: - Helpers

    private func focusedIdentifier() -> String? {
        let pred = NSPredicate(format: "hasFocus == true")
        return app.descendants(matching: .any).matching(pred).firstMatch.identifier.nilIfEmpty
    }

    private func anyFocused(prefix: String) -> Bool {
        let pred = NSPredicate(format: "identifier BEGINSWITH '\(prefix)' AND hasFocus == true")
        return app.descendants(matching: .any).matching(pred).count > 0
    }

    private func snap(_ label: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = label; shot.lifetime = .keepAlways; add(shot)
    }

    private func treeSnapshot(_ label: String) {
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = label; tree.lifetime = .keepAlways; add(tree)
    }

    // MARK: - Test

    /// Presses DOWN exactly 3 times from the tab bar and verifies focus reaches
    /// the video grid. Screenshots and an accessibility-tree dump are attached
    /// after every press so failures are immediately diagnosable.
    func test_ThreeDownPresses_LandOnVideoGrid() throws {
        // Wait for home feed to be ready.
        let chipBar = app.descendants(matching: .any)["home.chipBar"]
        guard chipBar.waitForExistence(timeout: 20) else {
            try captureAndSkip("home.chipBar did not appear — Home tab not loaded", in: app)
        }

        // On tvOS the outer HStack's .accessibilityIdentifier("home.shortsRow")
        // propagates to each Button child — so we look for that, not "shorts.card.*".
        let shortsPred = NSPredicate(format: "identifier == 'home.shortsRow' AND elementType == 9")
        let shortsCards = app.descendants(matching: .any).matching(shortsPred)
        let shortsResult = XCTWaiter().wait(
            for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "count > 0"), object: shortsCards)],
            timeout: 30
        )

        // Capture initial state and accessibility tree before attempting navigation.
        snap("0-initial")
        treeSnapshot("accessibility-tree-initial")

        let shortsPresent = shortsResult == .completed
        XCTContext.runActivity(named: "Shorts present: \(shortsPresent) (waiter=\(shortsResult.rawValue))") { _ in }

        guard shortsPresent else {
            try captureAndSkip("No 'home.shortsRow' buttons found after 30s — Shorts not in feed; captured initial state above", in: app)
        }

        // ── DOWN 1 ── tab-bar → chip-bar (or content if no chip-bar focus)
        remote.press(.down)
        Thread.sleep(forTimeInterval: 0.8)
        snap("1-after-first-down")
        let focused1 = focusedIdentifier() ?? "<nothing>"
        XCTContext.runActivity(named: "After DOWN 1 — focused: \(focused1)") { _ in }

        // ── DOWN 2 ── chip-bar → Shorts row
        remote.press(.down)
        Thread.sleep(forTimeInterval: 0.8)
        snap("2-after-second-down")
        let focused2 = focusedIdentifier() ?? "<nothing>"
        XCTContext.runActivity(named: "After DOWN 2 — focused: \(focused2)") { _ in }

        // ── DOWN 3 ── Shorts row → video grid  (the regression trigger)
        remote.press(.down)
        Thread.sleep(forTimeInterval: 0.8)
        snap("3-after-third-down")
        let focused3 = focusedIdentifier() ?? "<nothing>"
        XCTContext.runActivity(named: "After DOWN 3 — focused: \(focused3)") { _ in }

        treeSnapshot("accessibility-tree-after-3-downs")

        // ── Assertions ──
        // After 3 DOWNs: no home.shortsRow button should be focused,
        // and a video.card.* element should be focused.
        let shortsStillFocused: Bool = {
            let pred = NSPredicate(format: "identifier == 'home.shortsRow' AND hasFocus == true")
            return app.descendants(matching: .any).matching(pred).count > 0
        }()
        XCTAssertFalse(
            shortsStillFocused,
            "A Shorts button (home.shortsRow) still has focus after 3 DOWNs — DOWN does NOT escape the Shorts row. " +
            "focused1=\(focused1) focused2=\(focused2) focused3=\(focused3)"
        )
        XCTAssertTrue(
            anyFocused(prefix: "video.card."),
            "No video.card.* gained focus after 3 DOWNs. " +
            "focused1=\(focused1) focused2=\(focused2) focused3=\(focused3)"
        )
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
#endif

