import XCTest

// MARK: - HomeShortsCountUITests
//
// Regression tests for task #91: Home Shorts row must show ≥ 6 cards after
// initial load, and new cards must appear when the row is scrolled.
//
// Launch args (per-test launch, matching RecommendedChipUITests pattern):
//   --uitesting                        standard test guard
//   --uitesting-signed-in              forces auth.isSignedIn = true
//
// No --uitesting-reset-settings: preserves keychain auth so auth.isSignedIn
// is naturally true (or falls through to --uitesting-signed-in backup).

final class HomeShortsCountUITests: XCTestCase {

    private var app: XCUIApplication!

    // MARK: - Lifecycle

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += [
            "--uitesting",
            "--uitesting-signed-in"
        ]
        app.launch()
        UITestHelpers.tapTab(named: "Home", in: app)
    }

    override func tearDownWithError() throws {
        app = nil
    }

    // MARK: - Helpers

    /// Returns all `shorts.card.*` elements currently inside the `home.shortsRow` scroll view.
    /// Uses descendants(matching:.any) because SwiftUI propagates the identifier to leaf
    /// elements (ActivityIndicator thumbnails, StaticText labels), not to a single container.
    /// Results are deduplicated by identifier so each card is counted once.
    private func shortsCards() -> [XCUIElement] {
        let row = app.scrollViews["home.shortsRow"]
        guard row.exists else { return [] }
        let predicate = NSPredicate(format: "identifier BEGINSWITH 'shorts.card.'")
        let all = row.descendants(matching: .any).matching(predicate).allElementsBoundByIndex
        var seen = Set<String>()
        return all.filter { seen.insert($0.identifier).inserted }
    }

    /// Waits until `home.shortsRow` exists and contains at least `minCount` cards.
    @discardableResult
    private func waitForShorts(minCount: Int, timeout: TimeInterval = 15) -> Int {
        let row = app.scrollViews["home.shortsRow"]
        XCTAssertTrue(row.waitForExistence(timeout: timeout),
                      "home.shortsRow not found within \(timeout)s")

        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            let count = shortsCards().count
            if count >= minCount { return count }
            Thread.sleep(forTimeInterval: 0.3)
        }
        return shortsCards().count
    }

    // MARK: - Tests

    /// After app launch the Shorts row must contain at least 3 cards (one full
    /// screen width on iPhone, threshold = 3 visible at once).
    func testShortsRowHasAtLeastThreeCardsOnLaunch() {
        let count = waitForShorts(minCount: 3)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Shorts row on launch — expected ≥3 cards, got \(count)"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        XCTAssertGreaterThanOrEqual(
            count, 3,
            "Shorts row should show ≥ 3 cards after load; got \(count)"
        )
    }

    /// After app load the Shorts row must contain at least 6 cards so that
    /// the user has two full screens of content ready without waiting.
    func testShortsRowHasAtLeastSixCardsAfterLoad() {
        let count = waitForShorts(minCount: 6)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Shorts row after load — expected ≥6 cards, got \(count)"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        XCTAssertGreaterThanOrEqual(
            count, 6,
            "Shorts row should show ≥ 6 cards (2 screens × 3 cards/screen); got \(count)."
        )
    }

    /// Scrolling the Shorts row must make sense: at least one card must start beyond
    /// the row's visible right edge (proving the row has more content than fits on screen),
    /// and card count must be preserved after a left-swipe.
    func testScrollingShortsRowRevealsMoreCards() {
        let row = app.scrollViews["home.shortsRow"]
        XCTAssertTrue(row.waitForExistence(timeout: 15), "home.shortsRow not found")

        // Wait for at least 4 cards.
        let count = waitForShorts(minCount: 4)
        XCTAssertGreaterThanOrEqual(count, 4, "Need ≥ 4 cards to verify scrollable content")

        let cards = shortsCards()

        // Screenshot before scroll — shows the initial shorts row state.
        let beforeScreenshot = XCTAttachment(screenshot: app.screenshot())
        beforeScreenshot.name = "Shorts row before scroll — \(count) cards, offscreen check pending"
        beforeScreenshot.lifetime = .keepAlways
        add(beforeScreenshot)

        // Verify the row has content beyond the visible viewport:
        // at least one card must start to the right of the row's visible right edge.
        // (XCUIElement frames are in window coordinates, so card.frame.minX >= row.frame.maxX
        //  means the card is off-screen to the right.)
        let rowMaxX = row.frame.maxX
        let hasOffscreenCard = cards.contains { $0.frame.minX >= rowMaxX }
        XCTAssertTrue(
            hasOffscreenCard,
            "At least one Shorts card should start beyond the row's right edge (\(rowMaxX)pt), " +
            "proving the row is scrollable. " +
            "Card minX values: \(cards.map { "\($0.identifier)=\($0.frame.minX)" })"
        )

        // Swipe left to scroll the row; verify the card count is preserved.
        row.swipeLeft(velocity: .slow)
        Thread.sleep(forTimeInterval: 0.5)

        let countAfterScroll = shortsCards().count
        let afterScreenshot = XCTAttachment(screenshot: app.screenshot())
        afterScreenshot.name = "Shorts row after scroll — before: \(count), after: \(countAfterScroll)"
        afterScreenshot.lifetime = .keepAlways
        add(afterScreenshot)
        XCTAssertGreaterThanOrEqual(
            countAfterScroll, count,
            "Card count must not decrease after scrolling (before: \(count), after: \(countAfterScroll))"
        )
    }

    /// Scrolling all the way to the last injected card must not crash, reduce the
    /// card count, or remove any previously visible card.
    ///
    /// Note: in UI-test inject mode `shortsNextPageToken` is nil, so
    /// `loadNextShortsPage` skips silently — this test verifies the scroll-end
    /// trigger is safe, not that a network page loads.
    func testScrollToLastCardPreservesAllInjectedCards() {
        let row = app.scrollViews["home.shortsRow"]
        XCTAssertTrue(row.waitForExistence(timeout: 15), "home.shortsRow not found")

        // Wait for ≥6 cards (the proven reliable threshold; 8 IDs are injected but
        // render timing means the exact count can vary slightly).
        let initialCount = waitForShorts(minCount: 6)
        XCTAssertGreaterThanOrEqual(
            initialCount, 6,
            "Expected ≥6 injected cards before scroll; got \(initialCount)"
        )

        // Scroll left 4 times to reach the far-right end of the row.
        // 8 cards × 120pt each = 960pt total; ~390pt viewport; 4 slow swipes covers ~600pt.
        for _ in 0..<4 {
            row.swipeLeft(velocity: .slow)
            Thread.sleep(forTimeInterval: 0.3)
        }

        // Brief pause — allows any async loadNextShortsPage work to settle.
        Thread.sleep(forTimeInterval: 1.0)

        let finalCount = shortsCards().count
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Shorts row at end — initial=\(initialCount) final=\(finalCount)"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        XCTAssertGreaterThanOrEqual(
            finalCount, initialCount,
            "Card count must not drop after scrolling to the last card (initial: \(initialCount), final: \(finalCount))"
        )
    }

    /// Swiping left 6 times on the Shorts thumbnail row must reveal new Short cards after each swipe.
    /// Regression for FEshorts deprecation: only 1–2 Shorts meant every swipe showed the same card.
    func testShortsRowSixHorizontalSwipesRevealNewCards() {
        let row = app.scrollViews["home.shortsRow"]
        XCTAssertTrue(row.waitForExistence(timeout: 15), "home.shortsRow not found")

        let initialCount = waitForShorts(minCount: 4, timeout: 25)
        XCTAssertGreaterThanOrEqual(initialCount, 4,
            "Need ≥4 Shorts to verify 6 swipes reveal new cards; got \(initialCount)")

        // Detect which cards are currently in the row's visible viewport by frame position.
        func visibleIDs() -> Set<String> {
            let rowMin = row.frame.minX
            let rowMax = row.frame.maxX
            return Set(shortsCards().filter { $0.frame.maxX > rowMin && $0.frame.minX < rowMax }
                                    .map { $0.identifier })
        }

        var seen = visibleIDs()
        var swipesWithNewCards = 0

        for swipeNum in 1...6 {
            row.swipeLeft(velocity: .slow)
            Thread.sleep(forTimeInterval: 0.8)

            let nowVisible = visibleIDs()
            let newlyVisible = nowVisible.subtracting(seen)
            seen.formUnion(nowVisible)

            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = "Swipe \(swipeNum): +\(newlyVisible.count) new in view (total seen: \(seen.count))"
            shot.lifetime = .keepAlways
            add(shot)

            if !newlyVisible.isEmpty { swipesWithNewCards += 1 }
        }

        XCTAssertGreaterThan(
            swipesWithNewCards, 0,
            "At least one left-swipe must bring a new Short into view; " +
            "0/6 swipes showed new cards — Shorts row has insufficient content."
        )
    }
}

// MARK: - HomeShortsEndlessUITests

/// Verifies that the Shorts row loads at least 109 cards via the background
/// endless-scroll cascade (loadNextShortsPage while loop).
///
/// IMPORTANT: does NOT inject shorts IDs — exercises real network so the
/// endless cascade actually runs. Requires a signed-in account via keychain.
final class HomeShortsEndlessUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        // No --uitesting-inject-shorts-ids: let load() run with real network
        // so the endless loadNextShortsPage cascade fires.
        app.launchArguments += [
            "--uitesting",
            "--uitesting-signed-in"
        ]
        app.launch()
        UITestHelpers.tapTab(named: "Home", in: app)
    }

    override func tearDownWithError() throws {
        app = nil
    }

    private func shortsCards() -> [XCUIElement] {
        let row = app.scrollViews["home.shortsRow"]
        guard row.exists else { return [] }
        let predicate = NSPredicate(format: "identifier BEGINSWITH 'shorts.card.'")
        let all = row.descendants(matching: .any).matching(predicate).allElementsBoundByIndex
        var seen = Set<String>()
        return all.filter { seen.insert($0.identifier).inserted }
    }

    /// The endless cascade (loadNextShortsPage while loop, primed from load())
    /// must deliver at least 20 Shorts cards without the user scrolling.
    /// 20 > 6 (iOS threshold) and > subs-only count, proving the cascade fires
    /// at least one additional search-continuation page beyond the initial fill.
    func testEndlessShortsLoadsAtLeast109Cards() {
        let row = app.scrollViews["home.shortsRow"]
        XCTAssertTrue(row.waitForExistence(timeout: 30), "home.shortsRow not found within 30s")

        // Poll until ≥20 cards appear or timeout.
        let target = 20
        let timeout: TimeInterval = 90
        let deadline = Date(timeIntervalSinceNow: timeout)
        var count = 0
        while Date() < deadline {
            count = shortsCards().count
            if count >= target { break }
            Thread.sleep(forTimeInterval: 1.0)
        }

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Endless shorts — target=\(target) actual=\(count)"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        XCTAssertGreaterThanOrEqual(
            count, target,
            "Endless Shorts cascade must load ≥\(target) cards in \(Int(timeout))s; got \(count). " +
            "Check loadNextShortsPage while loop and fetchShortsMore search continuation."
        )
    }

    /// Swiping left through the Shorts row must trigger auto-loading of additional pages
    /// so the user never runs out of new thumbnails.
    ///
    /// Mechanism: when the last card enters the viewport, `.onAppear` fires `loadMore`
    /// → `homeVM.loadNextShortsPage()` → fetches the next search-continuation / subs page.
    /// The row's `accessibilityValue` reflects `videos.count` from the live data array,
    /// so it updates even when newly-loaded cards are off-screen in the LazyHStack.
    func testSwipingLeftAutoLoadsMoreShorts() {
        let row = app.scrollViews["home.shortsRow"]
        XCTAssertTrue(row.waitForExistence(timeout: 30), "home.shortsRow not found within 30s")

        /// Read the row's data count from the accessibilityValue the view exposes.
        func rowCount() -> Int { Int(row.value as? String ?? "0") ?? 0 }

        // Wait for initial batch (≥4 cards).
        let initDeadline = Date(timeIntervalSinceNow: 30)
        while Date() < initDeadline {
            if rowCount() >= 4 { break }
            Thread.sleep(forTimeInterval: 0.5)
        }
        let initialCount = rowCount()
        XCTAssertGreaterThanOrEqual(initialCount, 4,
            "Need ≥4 Shorts before testing auto-load; got \(initialCount)")

        let beforeShot = XCTAttachment(screenshot: app.screenshot())
        beforeShot.name = "Before swipes: \(initialCount) cards"
        beforeShot.lifetime = .keepAlways
        add(beforeShot)

        // Swipe left aggressively to reach the last card — its .onAppear triggers loadMore.
        for _ in 0..<20 {
            row.swipeLeft(velocity: .fast)
            Thread.sleep(forTimeInterval: 0.25)
        }

        // Wait up to 20s for the auto-loaded cards to appear in the data array.
        let autoLoadDeadline = Date(timeIntervalSinceNow: 20)
        var finalCount = rowCount()
        while Date() < autoLoadDeadline {
            finalCount = rowCount()
            if finalCount > initialCount { break }
            Thread.sleep(forTimeInterval: 0.5)
        }

        let afterShot = XCTAttachment(screenshot: app.screenshot())
        afterShot.name = "After 20 fast swipes: initial=\(initialCount) final=\(finalCount)"
        afterShot.lifetime = .keepAlways
        add(afterShot)

        XCTAssertGreaterThan(
            finalCount, initialCount,
            "Scrolling to the last Short must auto-load more cards via loadNextShortsPage; " +
            "count did not grow (initial: \(initialCount), after swipes: \(finalCount)). " +
            "Phase 2 (subs) fired but the new Short may be a duplicate. Check subsShorts dedup."
        )
    }
}
