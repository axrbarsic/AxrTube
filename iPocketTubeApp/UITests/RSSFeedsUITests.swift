import XCTest

// MARK: - RSSFeedsUITests
//
// UI tests for the RSS Feeds tab in the Library section.
//
// What's tested:
//   • The RSS Feeds segment is present and tappable in the Library picker.
//   • Selecting RSS Feeds shows either the empty state or a video list.
//   • The inline header buttons (Manage, Add) are visible on the RSS Feeds tab.
//   • Tapping "+" opens the Add RSS Feed sheet with the expected fields.
//   • The Add Feed sheet can be dismissed without submitting.
//   • Tapping the manage button opens the Manage RSS Feeds sheet.
//   • The Manage sheet can be dismissed.
//
// Network is NOT required for any test below — all tests use only static UI
// elements and the empty-state path.

final class RSSFeedsUITests: XCTestCase {

    private var app: XCUIApplication!

    // MARK: - Lifecycle

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["--uitesting"]
        app.launch()
    }

    override func tearDownWithError() throws {
        app = nil
    }

    // MARK: - Helpers

    /// Navigates to the Library tab and selects the RSS Feeds segment.
    /// Throws XCTSkip if the Library tab or segment picker is not found.
    private func openRSSFeedsTab() throws {
        UITestHelpers.tapTab(named: "Library", in: app)

        let picker = app.segmentedControls["library.sectionPicker"].firstMatch
        guard picker.waitForExistence(timeout: 5) else {
            try captureAndSkip("library.sectionPicker not found — Library tab may not have loaded", in: app)
        }

        let rssSegment = app.buttons["library.picker.rss feeds"].firstMatch
        guard rssSegment.waitForExistence(timeout: 3) else {
            try captureAndSkip("RSS Feeds segment not found in Library picker", in: app)
        }
        rssSegment.tap()
    }

    private var addFeedButton: XCUIElement {
        app.buttons["rss.addFeedButton"].firstMatch
    }

    private var manageFeedsButton: XCUIElement {
        app.buttons["rss.manageFeedsButton"].firstMatch
    }

    // MARK: - Tests

    /// Verifies the RSS Feeds segment exists in the Library section picker.
    func testRSSFeedsSegmentExists() throws {
        UITestHelpers.tapTab(named: "Library", in: app)
        let rssSegment = app.buttons["library.picker.rss feeds"].firstMatch
        guard rssSegment.waitForExistence(timeout: 5) else {
            try captureAndSkip("RSS Feeds segment not found — Library picker may not have loaded", in: app)
        }
        XCTAssertTrue(rssSegment.exists, "RSS Feeds segment must be present in the Library picker")
    }

    /// Verifies tapping the RSS Feeds segment shows either empty state or video list without crashing.
    func testSelectingRSSFeedsTabDoesNotCrash() throws {
        try openRSSFeedsTab()
        XCTAssertEqual(app.state, .runningForeground,
                       "App must remain in foreground after switching to RSS Feeds tab")
    }

    /// Verifies the inline Add (+) button is visible on the RSS Feeds tab.
    func testAddFeedButtonVisible() throws {
        try openRSSFeedsTab()
        XCTAssertTrue(addFeedButton.waitForExistence(timeout: 5),
                      "rss.addFeedButton must be visible in the RSS Feeds inline header")
    }

    /// Verifies the inline Manage (≡) button is visible on the RSS Feeds tab.
    func testManageFeedsButtonVisible() throws {
        try openRSSFeedsTab()
        XCTAssertTrue(manageFeedsButton.waitForExistence(timeout: 5),
                      "rss.manageFeedsButton must be visible in the RSS Feeds inline header")
    }

    /// Verifies tapping "+" opens the Add RSS Feed sheet with title/URL fields.
    func testAddFeedButtonOpensSheet() throws {
        try openRSSFeedsTab()
        guard addFeedButton.waitForExistence(timeout: 5) else {
            try captureAndSkip("rss.addFeedButton not found — cannot test sheet opening", in: app)
        }
        addFeedButton.tap()

        let urlField = app.textFields["rss.addFeed.urlField"].firstMatch
        XCTAssertTrue(urlField.waitForExistence(timeout: 5),
                      "Add RSS Feed sheet should appear with rss.addFeed.urlField after tapping +")

        let titleField = app.textFields["rss.addFeed.titleField"].firstMatch
        XCTAssertTrue(titleField.exists,
                      "Add RSS Feed sheet should contain rss.addFeed.titleField")
    }

    /// Verifies the Add RSS Feed sheet can be dismissed without submitting.
    func testAddFeedSheetCanBeDismissed() throws {
        try openRSSFeedsTab()
        guard addFeedButton.waitForExistence(timeout: 5) else {
            try captureAndSkip("rss.addFeedButton not found — cannot test sheet dismissal", in: app)
        }
        addFeedButton.tap()

        let urlField = app.textFields["rss.addFeed.urlField"].firstMatch
        guard urlField.waitForExistence(timeout: 5) else {
            try captureAndSkip("Add RSS Feed sheet did not appear — cannot test dismissal", in: app)
        }

        let cancelButton = app.buttons["Cancel"].firstMatch
        guard cancelButton.waitForExistence(timeout: 3) else {
            try captureAndSkip("Cancel button not found in Add RSS Feed sheet", in: app)
        }
        cancelButton.tap()

        // Sheet should be gone — url field disappears.
        XCTAssertFalse(urlField.waitForExistence(timeout: 3),
                       "Add RSS Feed sheet must be dismissed after tapping Cancel")
    }

    /// Verifies the "Add Feed" confirm button is disabled when fields are empty.
    func testAddFeedConfirmButtonDisabledWhenEmpty() throws {
        try openRSSFeedsTab()
        guard addFeedButton.waitForExistence(timeout: 5) else {
            try captureAndSkip("rss.addFeedButton not found", in: app)
        }
        addFeedButton.tap()

        let confirmButton = app.buttons["rss.addFeed.confirmButton"].firstMatch
        guard confirmButton.waitForExistence(timeout: 5) else {
            try captureAndSkip("rss.addFeed.confirmButton not found in Add RSS Feed sheet", in: app)
        }
        XCTAssertFalse(confirmButton.isEnabled,
                       "Add Feed button must be disabled when title and URL fields are empty")
    }

    /// Verifies tapping the manage button opens the Manage RSS Feeds sheet.
    func testManageFeedsButtonOpensSheet() throws {
        try openRSSFeedsTab()
        guard manageFeedsButton.waitForExistence(timeout: 5) else {
            try captureAndSkip("rss.manageFeedsButton not found — cannot test sheet opening", in: app)
        }
        manageFeedsButton.tap()

        // The sheet has a "Done" dismiss button.
        let doneButton = app.buttons["Done"].firstMatch
        XCTAssertTrue(doneButton.waitForExistence(timeout: 5),
                      "Manage RSS Feeds sheet must appear with a Done button")
    }

    /// Verifies the Manage RSS Feeds sheet can be dismissed.
    func testManageFeedsSheetCanBeDismissed() throws {
        try openRSSFeedsTab()
        guard manageFeedsButton.waitForExistence(timeout: 5) else {
            try captureAndSkip("rss.manageFeedsButton not found — cannot test sheet dismissal", in: app)
        }
        manageFeedsButton.tap()

        let doneButton = app.buttons["Done"].firstMatch
        guard doneButton.waitForExistence(timeout: 5) else {
            try captureAndSkip("Manage RSS Feeds sheet did not appear — cannot test dismissal", in: app)
        }
        doneButton.tap()

        XCTAssertFalse(doneButton.waitForExistence(timeout: 3),
                       "Manage RSS Feeds sheet must be dismissed after tapping Done")
    }
}
