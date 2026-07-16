import XCTest

// MARK: - HomeInteractionsUITests
//
// Combined from SearchUITests (13 tests) + WatchLaterContextMenuUITests (3 tests).
// All tests share a single app launch with --uitesting.
//
// SearchUITests: search bar, suggestions, filters, results, player open, history.
// WatchLaterContextMenuUITests: context-menu regression for browse/edit_playlist (#fix).

final class HomeInteractionsUITests: XCTestCase {

    // MARK: - Shared app lifecycle

    private static var sharedApp: XCUIApplication!
    private var app: XCUIApplication { HomeInteractionsUITests.sharedApp }

    override class func setUp() {
        super.setUp()
        sharedApp = XCUIApplication()
        sharedApp.launchArguments += ["--uitesting", "--uitesting-disable-tos-player-on-ios"]
        sharedApp.launch()
    }

    override class func tearDown() {
        sharedApp.terminate()
        sharedApp = nil
        super.tearDown()
    }

    // MARK: - Per-test reset

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        // Dismiss any alert left by a previous test (e.g. Watch Later success/error).
        let alert = app.alerts.firstMatch
        if alert.waitForExistence(timeout: 1) {
            let okButton = alert.buttons["OK"].firstMatch
            if okButton.exists { okButton.tap() } else { alert.buttons.firstMatch.tap() }
        }
        // Dismiss player if open.
        let backButton = app.buttons["player.backButton"].firstMatch
        if backButton.waitForExistence(timeout: 2) {
            backButton.tap()
            _ = app.buttons["Home"].waitForExistence(timeout: 3)
        }
        // Dismiss mini-player if present.
        let closeButton = app.buttons["miniPlayer.closeButton"].firstMatch
        if closeButton.waitForExistence(timeout: 2) {
            closeButton.tap()
        }
        // Navigate to Home tab to dismiss any active keyboard (left by search tests)
        // and ensure the home feed is visible before WatchLater tests need it.
        UITestHelpers.tapTab(named: "Home", in: app)
    }

    // MARK: - Search helpers

    private func openSearch() {
        UITestHelpers.tapTab(named: "Search", in: app)
    }

    private var searchBar: XCUIElement {
        app.textFields["search.bar"]
    }

    /// Navigates to Search, clears any previous query, types `query`, and submits.
    private func search(for query: String) {
        openSearch()
        let bar = searchBar
        XCTAssertTrue(bar.waitForExistence(timeout: 5), "search.bar must exist")
        bar.tap()
        // Clear any text left from a prior test in the shared-launch session.
        let clearButton = app.buttons["search.clearButton"].firstMatch
        if clearButton.waitForExistence(timeout: 1) {
            clearButton.tap()
        }
        bar.tap()
        bar.typeText(query)
        app.keyboards.buttons["search"].firstMatch.tap()
    }

    // MARK: - WatchLater helpers

    /// Navigates to the Home tab and waits for at least one video card.
    private func firstHomeCard() throws -> XCUIElement {
        UITestHelpers.tapTab(named: "Home", in: app)
        guard let card = UITestHelpers.waitForVideoCards(in: app, timeout: 60) else {
            try captureAndSkip("No video cards on Home — network unavailable or home feed still loading", in: app)
        }
        return card
    }

    /// Long-presses `element` and returns the "Save to Watch Later" menu button, or nil.
    private func openContextMenuWatchLaterButton(on element: XCUIElement) -> XCUIElement? {
        element.press(forDuration: 1.0)
        let button = app.buttons["Save to Watch Later"].firstMatch
        guard button.waitForExistence(timeout: 5) else { return nil }
        return button
    }

    // MARK: - Tests (from SearchUITests)

    func testSearchBarAppearsOnSearchTab() {
        openSearch()
        XCTAssertTrue(searchBar.waitForExistence(timeout: 5),
                      "search.bar must appear after tapping the Search tab")
        XCTAssertTrue(searchBar.isHittable, "search.bar must be hittable")
    }

    func testSearchTabOpensWithoutCrash() {
        openSearch()
        Thread.sleep(forTimeInterval: 1)
        XCTAssertEqual(app.state, .runningForeground,
                       "App should still be running after opening the Search tab")
    }

    func testTypingQueryShowsSuggestions() throws {
        openSearch()
        let bar = searchBar
        guard bar.waitForExistence(timeout: 5) else {
            XCTFail("search.bar not found")
            return
        }
        bar.tap()
        let clearButton = app.buttons["search.clearButton"].firstMatch
        if clearButton.waitForExistence(timeout: 1) { clearButton.tap() }
        bar.tap()
        bar.typeText("swift")

        // Use a type-agnostic predicate: SwiftUI List renders as UICollectionView on iOS 16+,
        // so app.tables[...] will not find it — search all element types by identifier instead.
        let suggestionsPredicate = NSPredicate(format: "identifier == 'search.suggestionsContainer'")
        let suggestions = app.descendants(matching: .any).matching(suggestionsPredicate).firstMatch
        guard suggestions.waitForExistence(timeout: 20) else {
            try captureAndSkip("search.suggestionsContainer did not appear within 20 s — network may be unavailable", in: app)
        }
        XCTAssertGreaterThan(suggestions.cells.count, 0,
                             "At least one suggestion should appear after typing 'swift'")
    }

    func testClearButtonEmptiesQuery() throws {
        openSearch()
        let bar = searchBar
        guard bar.waitForExistence(timeout: 5) else {
            XCTFail("search.bar not found")
            return
        }
        bar.tap()
        let existingClear = app.buttons["search.clearButton"].firstMatch
        if existingClear.waitForExistence(timeout: 1) { existingClear.tap() }
        bar.tap()
        bar.typeText("swift")
        XCTAssertEqual(bar.value as? String, "swift",
                       "Search bar should contain the typed query before clearing")

        let clearButton = app.buttons["search.clearButton"]
        XCTAssertTrue(clearButton.waitForExistence(timeout: 3),
                      "search.clearButton should appear when query is non-empty")
        clearButton.tap()
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertNotEqual(bar.value as? String, "swift",
                          "Search bar value should change after tapping clear")
    }

    func testSearchReturnsVideoCards() throws {
        search(for: "swift programming")
        let results = app.scrollViews["search.results"]
        guard results.waitForExistence(timeout: 5) else {
            XCTFail("search.results container did not appear — network may be unavailable")
            return
        }
        guard let _ = UITestHelpers.waitForVideoCards(in: app, timeout: 20) else {
            XCTFail("No video cards appeared in search results within 20 s")
            return
        }
    }

    func testNoErrorAlertOnSearch() throws {
        search(for: "swift")
        Thread.sleep(forTimeInterval: 10)
        UITestHelpers.assertNoErrorAlert(in: app)
    }

    func testFilterSheetOpensAndCloses() throws {
        search(for: "swift")
        _ = UITestHelpers.waitForVideoCards(in: app, timeout: 20)

        let filterButton = app.buttons["search.filterButton"]
        guard filterButton.waitForExistence(timeout: 5) else {
            XCTFail("search.filterButton not found")
            return
        }
        filterButton.tap()

        let sheet = app.otherElements["search.filterSheet"]
        XCTAssertTrue(sheet.waitForExistence(timeout: 5),
                      "search.filterSheet should appear after tapping the filter button")

        let cancelButton = app.buttons["Cancel"]
        XCTAssertTrue(cancelButton.waitForExistence(timeout: 3), "Cancel button must exist in filter sheet")
        cancelButton.tap()

        XCTAssertFalse(sheet.waitForExistence(timeout: 3),
                       "search.filterSheet should be dismissed after tapping Cancel")
    }

    func testFilterSheetApplyCreatesActiveChip() throws {
        search(for: "swift")
        _ = UITestHelpers.waitForVideoCards(in: app, timeout: 20)

        let filterButton = app.buttons["search.filterButton"]
        guard filterButton.waitForExistence(timeout: 5) else {
            XCTFail("search.filterButton not found")
            return
        }
        filterButton.tap()

        let sheet = app.otherElements["search.filterSheet"]
        guard sheet.waitForExistence(timeout: 5) else {
            XCTFail("search.filterSheet did not appear")
            return
        }

        let thisWeekPredicate = NSPredicate(format: "label == 'This week' OR identifier == 'This week'")
        let thisWeekOption = app.descendants(matching: .any).matching(thisWeekPredicate).firstMatch
        let sheetForm = app.collectionViews.firstMatch
        UITestHelpers.scrollUntilVisible(thisWeekOption, in: sheetForm)
        XCTAssertTrue(thisWeekOption.waitForExistence(timeout: 5),
                      "'This week' option must be visible in the Upload date picker")
        thisWeekOption.tap()

        let applyButton = app.buttons["Apply"]
        XCTAssertTrue(applyButton.waitForExistence(timeout: 3), "Apply button must exist in filter sheet")
        applyButton.tap()

        let chipPredicate = NSPredicate(format: "label == 'This week'")
        let chip = app.staticTexts.matching(chipPredicate).firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 5),
                      "An active filter chip labelled 'This week' should appear after applying the filter")
    }

    func testTappingResultOpensPlayer() throws {
        search(for: "swift programming")
        guard let firstCard = UITestHelpers.waitForVideoCards(in: app, timeout: 20) else {
            XCTFail("No video cards in search results — network may be unavailable")
            return
        }
        XCTAssertTrue(UITestHelpers.openPlayer(from: firstCard, in: app),
                      "player.titleLabel should appear after tapping a search result")
    }

    func testSubmittedQueryAppearsInHistory() throws {
        search(for: "history test query")

        let bar = searchBar
        guard bar.waitForExistence(timeout: 5) else { XCTFail("search.bar not found"); return }
        bar.tap()
        app.buttons["search.clearButton"].firstMatch.tap()

        let historyRow = app.buttons["search.history.history test query"]
        XCTAssertTrue(historyRow.waitForExistence(timeout: 5),
                      "Submitted query should appear as a history row")
    }

    func testTappingHistoryRowTriggersSearch() throws {
        search(for: "history tap test")

        let bar = searchBar
        guard bar.waitForExistence(timeout: 5) else { XCTFail("search.bar not found"); return }
        bar.tap()
        app.buttons["search.clearButton"].firstMatch.tap()

        let historyRow = app.buttons["search.history.history tap test"]
        guard historyRow.waitForExistence(timeout: 5) else {
            XCTFail("History row not found — previous search may not have persisted")
            return
        }
        historyRow.tap()

        let results = app.scrollViews["search.results"]
        XCTAssertTrue(results.waitForExistence(timeout: 10),
                      "Tapping a history row should trigger the search and show results")
    }

    func testDeleteHistoryEntryRemovesRow() throws {
        search(for: "entry to delete")

        let bar = searchBar
        guard bar.waitForExistence(timeout: 5) else { XCTFail("search.bar not found"); return }
        bar.tap()
        app.buttons["search.clearButton"].firstMatch.tap()

        let deleteButton = app.buttons["Remove entry to delete from history"]
        guard deleteButton.waitForExistence(timeout: 5) else {
            XCTFail("Delete button for history entry not found")
            return
        }
        deleteButton.tap()

        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertFalse(app.buttons["search.history.entry to delete"].exists,
                       "History entry should be removed after tapping its delete button")
    }

    func testClearAllHistoryRemovesAllEntries() throws {
        search(for: "clear all test a")
        search(for: "clear all test b")

        let bar = searchBar
        guard bar.waitForExistence(timeout: 5) else { XCTFail("search.bar not found"); return }
        bar.tap()
        app.buttons["search.clearButton"].firstMatch.tap()

        let clearAll = app.buttons["search.history.clearAll"]
        guard clearAll.waitForExistence(timeout: 5) else {
            XCTFail("Clear History button not found")
            return
        }
        clearAll.tap()

        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertFalse(app.buttons["search.history.clear all test a"].exists,
                       "All history entries should be removed after Clear History")
        XCTAssertFalse(app.buttons["search.history.clear all test b"].exists,
                       "All history entries should be removed after Clear History")
    }

    // MARK: - Tests (from WatchLaterContextMenuUITests)

    func testA_ContextMenuAppearsOnLongPress() throws {
        let card = try firstHomeCard()
        card.press(forDuration: 1.0)
        let shareItem = app.buttons["Share"].firstMatch
        XCTAssertTrue(shareItem.waitForExistence(timeout: 5),
                      "Context menu 'Share' item should appear after long-pressing a video card")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.02)).tap()
    }

    func testA_WatchLaterMenuItemVisibleWhenSignedIn() throws {
        let card = try firstHomeCard()
        guard let button = openContextMenuWatchLaterButton(on: card) else {
            try captureAndSkip("'Save to Watch Later' not shown — account may not be signed in", in: app)
        }
        XCTAssertTrue(button.exists,
                      "'Save to Watch Later' context menu item must be visible for signed-in users")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.02)).tap()
    }

    func testA_SaveToWatchLaterShowsSuccessAlertNotError() throws {
        let card = try firstHomeCard()
        guard let button = openContextMenuWatchLaterButton(on: card) else {
            try captureAndSkip("'Save to Watch Later' not shown — account may not be signed in", in: app)
        }
        button.tap()

        let anyAlert = app.alerts.firstMatch
        XCTAssertTrue(anyAlert.waitForExistence(timeout: 10),
                      "An alert should appear after tapping 'Save to Watch Later'")

        let successAlert = app.alerts["Saved to Watch Later"].firstMatch
        let errorAlert   = app.alerts["Could Not Save"].firstMatch

        XCTAssertFalse(errorAlert.exists,
                       "Got 'Could Not Save' alert — endpoint returned an error. " +
                       "Check that InnerTubeAPI+Social uses 'browse/edit_playlist' (slash), not 'browse_edit_playlist' (underscore).")
        XCTAssertTrue(successAlert.exists,
                      "'Saved to Watch Later' success alert must appear after a successful API call")

        successAlert.buttons["OK"].tap()
    }
}
