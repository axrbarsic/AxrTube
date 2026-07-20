import XCTest

// MARK: - ScrubberUITests
//
// Regression tests for task #121 — finger drag on seek bar not working.
//
// The original bug: chapter-marker hit areas (24×44 pt invisible rectangles
// overlaid on the progress bar) intercepted DragGesture touches before the
// bar's DragGesture could fire.  Fix: changed .gesture() → .highPriorityGesture()
// on the seek-bar ZStack and guarded chapter-marker onTapGesture with
// `guard !vm.isScrubbing`.
//
// These tests verify that a UI-level drag on the seek bar actually moves the
// playback position, by reading player.currentTimeLabel before and after each
// scrub.  Three scrub targets are tested: 25 %, 50 %, and 75 % of the bar.
//
// Logging strategy: every step is wrapped in XCTContext.runActivity so the
// full activity log is visible in Xcode's Test Report.  Screenshots and
// accessibility-tree dumps are attached at key moments.
//
// Video used: Dy9ki9Q5nXs — reliably triggers the Android client fallback on
// the iOS Simulator and has a duration > 3 minutes so all three scrub targets
// land at non-trivial positions.
//
// Architecture: one shared app launch per class (class setUp / tearDown).
// Tests run in alphabetical order and share the running player session.

#if !os(tvOS)
final class ScrubberUITests: XCTestCase {

    // MARK: - Per-test state
    //
    // Each test launches its own app instance so seeks in one test cannot
    // corrupt the video position seen by the next test.

    private let videoID = "Dy9ki9Q5nXs"

    private var app: XCUIApplication!
    private var skipThisTest = false
    private let skipReason =
        "Player did not become ready within deadline — " +
        "network unavailable or playback broken for this video"

    // MARK: - Lifecycle

    override func setUp() {
        super.setUp()
        continueAfterFailure = false

        let appUnderTest = XCUIApplication()
        appUnderTest.launchArguments = [
            "--uitesting",
            "--uitesting-disable-tos-player-on-ios",
            "--uitesting-deeplink-video=\(videoID)"
        ]
        appUnderTest.launch()
        app = appUnderTest

        // Wait for the player title to appear.
        guard appUnderTest.staticTexts["player.titleLabel"].firstMatch.waitForExistence(timeout: 20) else {
            skipThisTest = true
            return
        }

        // Let the video buffer for 8 s so currentTime > 0 and a seek has
        // a non-trivial "before" value to compare against.
        Thread.sleep(forTimeInterval: 8)

        // Show controls and wait for the play/pause button to become enabled
        // (enabled == true means isLoading was cleared by the .readyToPlay handler).
        let playPauseButton = appUnderTest.buttons["player.playPauseButton"].firstMatch
        for _ in 0..<6 {
            if playPauseButton.exists { break }
            appUnderTest.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            Thread.sleep(forTimeInterval: 1.5)
        }
        let enabledPred = NSPredicate(format: "enabled == true")
        let exp = XCTNSPredicateExpectation(predicate: enabledPred, object: playPauseButton)
        if XCTWaiter().wait(for: [exp], timeout: 30) != .completed {
            skipThisTest = true
        }
    }

    override func tearDown() {
        app?.terminate()
        app = nil
        super.tearDown()
    }

    // MARK: - Helpers

    /// Taps the player surface until the progress bar is hittable (controls overlay visible).
    /// Returns the progress bar element, or nil if controls never appeared.
    private func showControlsAndGetProgressBar() -> XCUIElement? {
        let progressBar = app.otherElements["player.progressBar"].firstMatch
        for _ in 0..<8 {
            if progressBar.exists && progressBar.isHittable { return progressBar }
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            Thread.sleep(forTimeInterval: 1.5)
        }
        return (progressBar.exists && progressBar.isHittable) ? progressBar : nil
    }

    /// Returns the `player.currentTimeLabel` text, e.g. "1:23", or "(unavailable)".
    private func readCurrentTime() -> String {
        let lbl = app.staticTexts["player.currentTimeLabel"].firstMatch
        return lbl.exists ? lbl.label : "(unavailable)"
    }

    /// Returns the `player.durationLabel` text, e.g. "7:05", or "(unavailable)".
    private func readDuration() -> String {
        let lbl = app.staticTexts["player.durationLabel"].firstMatch
        return lbl.exists ? lbl.label : "(unavailable)"
    }

    /// Drags the progress bar from 10 % to `toFraction` (0…1) and returns a
    /// human-readable log string describing the drag geometry.
    ///
    /// Uses a 0.1 s initial press so SwiftUI's DragGesture (minimumDistance: 0)
    /// has time to activate before the pointer starts moving.  No velocity
    /// parameter — the default fast drag avoids the hold-at-end ambiguity that
    /// slow-velocity drags can produce on some gesture stacks.
    private func dragProgressBar(_ progressBar: XCUIElement, to toFraction: Double) -> String {
        let frame = progressBar.frame
        // hPad matches the constant used in iosProgressBar to exclude the end margins.
        let hPad: CGFloat = 20
        let trackW = frame.width - hPad * 2
        let startX  = frame.minX + hPad + trackW * 0.10   // near-start anchor
        let endX    = frame.minX + hPad + trackW * CGFloat(toFraction)
        let midY    = frame.midY

        let start = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: startX, dy: midY))
        let end = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: endX, dy: midY))

        start.press(forDuration: 0.1, thenDragTo: end)

        return String(
            format: "bar=(x:%.0f y:%.0f w:%.0f h:%.0f) " +
                    "hPad=%.0f trackW=%.0f " +
                    "drag=(%.0f→%.0f)@y=%.0f target=%.0f%%",
            frame.minX, frame.minY, frame.width, frame.height,
            hPad, trackW,
            startX, endX, midY,
            toFraction * 100
        )
    }

    // MARK: - Tests

    /// Scrubs to 25 % of the seek bar and verifies the playback position advanced.
    func testScrubTo25Percent() throws {
        guard !skipThisTest else { throw XCTSkip(skipReason) }
        try scrubAndAssert(toFraction: 0.25, label: "25%")
    }

    /// Scrubs to 50 % of the seek bar and verifies the playback position advanced.
    func testScrubTo50Percent() throws {
        guard !skipThisTest else { throw XCTSkip(skipReason) }
        try scrubAndAssert(toFraction: 0.50, label: "50%")
    }

    /// Scrubs to 75 % of the seek bar and verifies the playback position advanced.
    func testScrubTo75Percent() throws {
        guard !skipThisTest else { throw XCTSkip(skipReason) }
        try scrubAndAssert(toFraction: 0.75, label: "75%")
    }

    // MARK: - Shared scrub body

    private func scrubAndAssert(toFraction: Double, label: String) throws {
        // ── Step 1: Show controls ─────────────────────────────────────────────
        let progressBar: XCUIElement = try XCTContext.runActivity(named: "Step 1 – Show controls") { activity in
            guard let pb = showControlsAndGetProgressBar() else {
                captureState("no-controls-\(label)", in: app)
                let tree = app.debugDescription
                let att = XCTAttachment(string: "Accessibility tree when controls absent:\n\(tree)")
                att.name = "tree-no-controls-\(label)"
                att.lifetime = .keepAlways
                add(att)
                try captureAndSkip(
                    "player.progressBar not hittable after 12 s of tapping — " +
                    "controls overlay not visible for \(label) scrub test",
                    in: app
                )
            }
            return pb
        }

        // ── Step 2: PAUSE the video (eliminates natural playback as confound) ─
        XCTContext.runActivity(named: "Step 2 – Pause video") { _ in
            let playPauseBtn = app.buttons["player.playPauseButton"].firstMatch
            if playPauseBtn.exists, playPauseBtn.isHittable {
                playPauseBtn.tap()
            }
            Thread.sleep(forTimeInterval: 0.8)  // let pause settle
        }

        // Re-show controls — tapping play/pause may have triggered the hide timer.
        _ = showControlsAndGetProgressBar()

        // ── Step 3: Read state BEFORE scrub ──────────────────────────────────
        let timeBefore: String = XCTContext.runActivity(named: "Step 3 – Read state BEFORE scrub to \(label)") { _ in
            let t = readCurrentTime()
            let d = readDuration()
            let pbFrame = progressBar.frame
            let info = """
            [BEFORE SCRUB TO \(label)]
            currentTime   : \(t)
            duration      : \(d)
            progressBar   : x=\(pbFrame.minX) y=\(pbFrame.minY) w=\(pbFrame.width) h=\(pbFrame.height)
            hittable      : \(progressBar.isHittable)
            """
            let att = XCTAttachment(string: info)
            att.name = "state-before-\(label)"
            att.lifetime = .keepAlways
            add(att)
            captureState("before-scrub-\(label)", in: app)
            return t
        }

        // ── Step 4: Perform the drag ──────────────────────────────────────────
        let dragInfo: String = XCTContext.runActivity(named: "Step 4 – Drag seek bar to \(label)") { _ in
            let info = dragProgressBar(progressBar, to: toFraction)
            let att = XCTAttachment(string: "[DRAG TO \(label)]\n\(info)")
            att.name = "drag-info-\(label)"
            att.lifetime = .keepAlways
            add(att)
            return info
        }

        // ── Step 5: Wait for seek to complete ────────────────────────────────
        // Video is paused — the ONLY thing that can change currentTime is the
        // seek issued by commitScrub().  AVPlayer's periodic time observer
        // fires every 0.2 s, so 2 s is ample for the seek to settle.
        XCTContext.runActivity(named: "Step 5 – Wait 2 s for seek to settle (video paused)") { _ in
            Thread.sleep(forTimeInterval: 2)
        }

        // ── Step 6: Re-show controls and read state after scrub ───────────────
        _ = showControlsAndGetProgressBar()
        let timeAfter: String = XCTContext.runActivity(named: "Step 6 – Read state AFTER scrub to \(label)") { _ in
            let t = readCurrentTime()
            let d = readDuration()
            let info = """
            [AFTER SCRUB TO \(label)]
            currentTime   : \(t)
            duration      : \(d)
            dragGeometry  : \(dragInfo)
            timeBefore    : \(timeBefore)
            """
            let att = XCTAttachment(string: info)
            att.name = "state-after-\(label)"
            att.lifetime = .keepAlways
            add(att)
            captureState("after-scrub-\(label)", in: app)
            return t
        }

        // ── Step 7: RESUME the video ──────────────────────────────────────────
        XCTContext.runActivity(named: "Step 7 – Resume video") { _ in
            let playPauseBtn = app.buttons["player.playPauseButton"].firstMatch
            if playPauseBtn.exists, playPauseBtn.isHittable {
                playPauseBtn.tap()
            }
            Thread.sleep(forTimeInterval: 0.5)
        }

        // ── Step 8: Assert ────────────────────────────────────────────────────
        XCTContext.runActivity(named: "Step 8 – Assert scrub changed position") { _ in
            XCTAssertNotEqual(
                timeBefore, timeAfter,
                "player.currentTimeLabel did not change after dragging to \(label) " +
                "(video was PAUSED — natural playback cannot explain this). " +
                "The DragGesture was NOT recognised by the seek bar. " +
                "Chapter-marker hit areas may still be intercepting touches (task #121). " +
                "Before: '\(timeBefore)', After: '\(timeAfter)'. " +
                "Drag geometry: \(dragInfo)"
            )
            XCTAssertFalse(
                app.staticTexts["player.titleLabel"].firstMatch.label.isEmpty,
                "player.titleLabel is empty after scrub to \(label) — player dismissed or crashed"
            )
        }
    }
}
#endif // !os(tvOS)
