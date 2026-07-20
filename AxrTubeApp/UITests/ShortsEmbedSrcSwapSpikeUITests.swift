#if os(iOS)
import XCTest

// AGENT-POST-RUN-CHECK: ui-tests-with-logs
//
// After every run of this test, load .github/skills/ui-tests-with-logs/SKILL.md and
// inspect the extracted device log. Classify every skip before closing the task:
//
// LEGITIMATE skip:
//   - "shortsSpike.statusLabel did not appear" / "ready notification never fired for
//     video 0" — network unavailable or YouTube embed blocked in the simulator.
//     Device log should show "[spike-nav] provisional navigation failed" or no
//     "[spike] ready" notice at all.
//
// BUG skip (must fix before closing):
//   - A skip reached AFTER "[spike] ready #0" appears in the device log — by that
//     point the WKWebView loaded successfully and the iframe-src-swap mechanism is
//     the only thing left under test, so a skip there means the swap itself broke.
//
// Log events to verify:
//   ✓ "[spike] ready #0" .. "[spike] ready #3" — one per video
//   ✓ "[spike] window #0 closed" .. "[spike] window #3 closed"
//   ✗ "[spike] ❌ error" — should never appear (errorCount must stay 0)
//
// RED FLAGS in device log:
//   - "[spike] ready #N" with the same duration as "[spike] ready #N-1" → the src
//     swap did not actually navigate the iframe (stale state from the previous video)
//   - Fewer than 4 "[spike] ready #" lines after 3 swaps → the injected user scripts
//     did not re-fire on the new frame

// MARK: - ShortsEmbedSrcSwapSpikeUITests
//
// Task 1 of docs/superpowers/plans/2026-06-12-tos-player-shorts-implementation-plan.md.
// GATES Tasks 2-10: if this test fails, STOP and revisit the architecture (e.g. the
// multi-WKWebView preload-pool approach in
// docs/superpowers/specs/2026-06-11-tos-player-shorts-design.md) before continuing.
//
// Verifies, across 3 iframe-src swaps (4 videos total):
//   1. freshReady     — each swap produces a new "ready" with a duration >0 and
//                        different from the previous video's.
//   2. ticksResume    — >=8 "tick" messages within ~3s of each swap's "ready".
//   3. tickRateStable — the last swap's tick count is within 0.5x-1.5x of the first's.
//   4. noErrors       — errorCount stays 0 throughout.
final class ShortsEmbedSrcSwapSpikeUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        app?.terminate()
        app = nil
    }

    /// Parses `vm.statusSummary` — "idx=N ready=[d0,d1,...] ticks=[t0,t1,...] errors=E".
    private func parseStatus(_ s: String) -> (ready: [Double], ticks: [Int], errors: Int)? {
        guard let readyRange = s.range(of: "ready=["),
              let readyEnd = s.range(of: "]", range: readyRange.upperBound..<s.endIndex),
              let ticksRange = s.range(of: "ticks=["),
              let ticksEnd = s.range(of: "]", range: ticksRange.upperBound..<s.endIndex),
              let errorsRange = s.range(of: "errors=")
        else { return nil }

        let readyStr = s[readyRange.upperBound..<readyEnd.lowerBound]
        let ticksStr = s[ticksRange.upperBound..<ticksEnd.lowerBound]
        let errorsStr = s[errorsRange.upperBound...].trimmingCharacters(in: .whitespaces)

        let ready = readyStr.split(separator: ",").compactMap { Double($0) }
        let ticks = ticksStr.split(separator: ",").compactMap { Int($0) }
        guard let errors = Int(errorsStr) else { return nil }
        return (ready, ticks, errors)
    }

    func testIframeSrcSwapRepeatedlyRefiresJSBridge() throws {
        app = XCUIApplication()
        // Register the video-0 Darwin notification expectations BEFORE launching:
        // the spike's WKWebView starts loading in onAppear and can post "ready"
        // (and close its tick window) within ~2s — faster than the UI-element
        // existence checks below take to complete. CFNotificationCenter does not
        // queue notifications for late observers, so registering these after the
        // existence checks risks missing them entirely.
        let ready0 = XCTDarwinNotificationExpectation(notificationName: "com.void.ipockettube.shortsspike.ready")
        let window0 = XCTDarwinNotificationExpectation(notificationName: "com.void.ipockettube.shortsspike.windowclosed")

        app.launchArguments = [
            "--uitesting",
            "--uitesting-reset-settings",
            "--uitesting-shorts-srcswap-spike",
        ]
        app.launch()

        let statusLabel = app.descendants(matching: .any)
            .matching(identifier: "shortsSpike.statusLabel").firstMatch
        guard statusLabel.waitForExistence(timeout: 15) else {
            throw XCTSkip("shortsSpike.statusLabel did not appear — spike view did not present")
        }

        let swapButton = app.buttons["shortsSpike.swapButton"]
        XCTAssertTrue(swapButton.waitForExistence(timeout: 5), "shortsSpike.swapButton not found")

        // ── Video 0: wait for first ready + its tick window ──────────────────
        guard XCTWaiter().wait(for: [ready0], timeout: 30) == .completed else {
            throw XCTSkip("ready notification never fired for video 0 — embed failed to load (network/YouTube availability)")
        }
        XCTAssertEqual(XCTWaiter().wait(for: [window0], timeout: 10), .completed, "tick window for video 0 never closed")

        // ── Swaps 1-3: tap Swap, wait for ready + window each time ───────────
        for i in 1...3 {
            let ready = XCTDarwinNotificationExpectation(notificationName: "com.void.ipockettube.shortsspike.ready")
            let window = XCTDarwinNotificationExpectation(notificationName: "com.void.ipockettube.shortsspike.windowclosed")
            swapButton.tap()
            XCTAssertEqual(XCTWaiter().wait(for: [ready], timeout: 15), .completed, "ready notification never fired for video \(i)")
            XCTAssertEqual(XCTWaiter().wait(for: [window], timeout: 10), .completed, "tick window for video \(i) never closed")
        }

        // ── Parse final status and check all 4 criteria ──────────────────────
        let summary = statusLabel.label
        guard let status = parseStatus(summary) else {
            XCTFail("could not parse statusSummary: '\(summary)'")
            return
        }
        print("[shorts-spike] final status: \(summary)")

        // 1. freshReady — 4 ready messages, each >0, consecutive entries differ.
        XCTAssertEqual(status.ready.count, 4, "expected 4 'ready' messages (1 per video), got \(status.ready.count)")
        for (i, d) in status.ready.enumerated() {
            XCTAssertGreaterThan(d, 0, "ready duration #\(i) was not >0 — got \(d)")
        }
        for i in 1..<status.ready.count {
            XCTAssertNotEqual(status.ready[i], status.ready[i - 1], "ready duration #\(i) (\(status.ready[i])) matches the previous video's (\(status.ready[i-1])) — src swap may not have navigated the iframe")
        }

        // 2. ticksResume — >=8 ticks in each 3s window.
        XCTAssertEqual(status.ticks.count, 4, "expected 4 tick-window counts, got \(status.ticks.count)")
        for (i, t) in status.ticks.enumerated() {
            XCTAssertGreaterThanOrEqual(t, 8, "tick window #\(i) only saw \(t) ticks (need >=8 within ~3s)")
        }

        // 3. tickRateStable — last window within 0.5x-1.5x of the first.
        let first = Double(status.ticks[0])
        let last = Double(status.ticks[3])
        XCTAssertTrue((first * 0.5...first * 1.5).contains(last), "tick rate drifted — first window=\(status.ticks[0]) last window=\(status.ticks[3])")

        // 4. noErrors
        XCTAssertEqual(status.errors, 0, "errorCount should be 0, got \(status.errors)")
    }
}
#endif
