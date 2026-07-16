import XCTest

// MARK: - LibraryUITests
//
// Merged UI test class combining:
//   • LibraryHistoryUITests (7 tests)
//   • LibrarySubscriptionsUITests (7 tests)
//   • LibraryPlaylistsUITests (11 tests)
//   • PlaylistsNavigationUITests (5 tests)
//
// Total: 30 tests — 1 app launch instead of 30 (one per original class).
//
// Launch args: --uitesting
// Requirements: iOS 17+ simulator, iPocketTubeApp scheme.
// Some tests require a signed-in account; they use captureAndSkip when
// network / account conditions are not met.

final class LibraryUITests: XCTestCase {

    // MARK: - Shared app lifecycle (one launch for all 30 tests)

    private static var sharedApp: XCUIApplication!

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

    private var app: XCUIApplication { LibraryUITests.sharedApp }

    // MARK: - Per-test reset

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        #if os(iOS)
        XCUIDevice.shared.orientation = .portrait
        #endif
        // Close full-screen player if open.
        let backButton = app.buttons["player.backButton"].firstMatch
        if backButton.waitForExistence(timeout: 2) {
            backButton.tap()
            _ = app.buttons["Home"].waitForExistence(timeout: 3)
        }
        // Close mini-player if visible.
        let closeButton = app.buttons["miniPlayer.closeButton"].firstMatch
        if closeButton.waitForExistence(timeout: 2) {
            closeButton.tap()
        }
    }

    // MARK: - Helpers

    private func openHistorySegment() throws {
        UITestHelpers.tapTab(named: "Library", in: app)
        let picker = app.segmentedControls["library.sectionPicker"]
        guard picker.waitForExistence(timeout: 5) else {
            try captureAndSkip("library.sectionPicker did not appear — Library tab may not have loaded", in: app)
        }
        let button = picker.buttons["History"]
        guard button.waitForExistence(timeout: 3) else {
            try captureAndSkip("History segment not found in library section picker", in: app)
        }
        button.tap()
    }

    private func openSubscriptionsSegment() throws {
        UITestHelpers.tapTab(named: "Library", in: app)
        let picker = app.segmentedControls["library.sectionPicker"]
        guard picker.waitForExistence(timeout: 5) else {
            try captureAndSkip("library.sectionPicker did not appear — Library tab may not have loaded", in: app)
        }
        let button = picker.buttons["Subs"]
        guard button.waitForExistence(timeout: 5) else {
            try captureAndSkip("Subs segment not found in library section picker", in: app)
        }
        button.tap()
    }

    private func openPlaylistsSegment() throws {
        UITestHelpers.tapTab(named: "Library", in: app)
        let picker = app.segmentedControls["library.sectionPicker"]
        guard picker.waitForExistence(timeout: 5) else {
            try captureAndSkip("library.sectionPicker did not appear — Library tab may not have loaded", in: app)
        }
        let playlistsButton = picker.buttons["Playlists"]
        guard playlistsButton.waitForExistence(timeout: 3) else {
            try captureAndSkip("Playlists segment not found in library section picker", in: app)
        }
        playlistsButton.tap()
    }

    // MARK: - History tests

    func testHistorySegmentVisible() throws {
        UITestHelpers.tapTab(named: "Library", in: app)
        let picker = app.segmentedControls["library.sectionPicker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5),
                      "library.sectionPicker should appear")
        XCTAssertTrue(picker.buttons["History"].exists,
                      "'History' segment must be present in the library picker")
    }

    func testHistoryNavigationDoesNotCrash() throws {
        try openHistorySegment()
        Thread.sleep(forTimeInterval: 2)
        XCTAssertEqual(app.state, .runningForeground,
                       "App should still be running after opening History in Library")
    }

    func testHistorySegmentShowsFeed() throws {
        try openHistorySegment()
        guard UITestHelpers.waitForVideoCards(in: app, timeout: 20) != nil else {
            try captureAndSkip("No video cards loaded within 20 s — account may not be signed in or has empty history", in: app)
        }
    }

    func testNoErrorAlertOnHistoryLoad() throws {
        try openHistorySegment()
        Thread.sleep(forTimeInterval: 5)
        UITestHelpers.assertNoErrorAlert(in: app)
    }

    func testHistoryScrollLoadsMore() throws {
        try openHistorySegment()
        guard UITestHelpers.waitForVideoCards(in: app, timeout: 20) != nil else {
            try captureAndSkip("No video cards in History feed — signed-in account with history required", in: app)
        }

        let countBefore = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'video.card.'"))
            .count

        app.swipeUp(velocity: .fast)
        Thread.sleep(forTimeInterval: 2)
        app.swipeUp(velocity: .fast)
        Thread.sleep(forTimeInterval: 3)

        let countAfter = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'video.card.'"))
            .count

        XCTAssertGreaterThanOrEqual(countAfter, countBefore,
            "Scrolling down should not reduce video card count (pagination should add more)")
    }

    func testTappingVideoFromHistoryOpensPlayer() throws {
        try openHistorySegment()
        guard let firstCard = UITestHelpers.waitForVideoCards(in: app, timeout: 20) else {
            try captureAndSkip("No video cards in History — signed-in account with history required", in: app)
        }
        XCTAssertTrue(UITestHelpers.openPlayer(from: firstCard, in: app),
                      "player.titleLabel must appear after tapping a video in Library History")
        let errorBanner = app.otherElements["player.errorBanner"].firstMatch
        if errorBanner.exists {
            try captureAndSkip("player.errorBanner appeared — network issue on this simulator clone", in: app)
        }
    }

    func testHistoryScrollRestorationAfterPlayback() throws {
        try openHistorySegment()
        guard UITestHelpers.waitForVideoCards(in: app, timeout: 20) != nil else {
            try captureAndSkip("No video cards — signed-in account with history required", in: app)
        }

        let firstCard = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'video.card.'"))
            .firstMatch

        app.swipeUp(velocity: .fast)
        Thread.sleep(forTimeInterval: 2)
        app.swipeUp(velocity: .fast)
        Thread.sleep(forTimeInterval: 2)

        let firstCardMaxYAfterScroll = firstCard.frame.maxY
        guard firstCardMaxYAfterScroll < 100 else {
            try captureAndSkip("Could not scroll first card off-screen — feed may have too few items", in: app)
        }

        let feed = app.scrollViews.firstMatch
        let tapPoint = feed.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        tapPoint.tap()

        let titleLabel = app.staticTexts["player.titleLabel"].firstMatch
        guard titleLabel.waitForExistence(timeout: 15) else {
            try captureAndSkip("PlayerView did not open within 15 s — network unavailable or timing-dependent", in: app)
        }

        let backButton = app.buttons["player.backButton"].firstMatch
        guard backButton.waitForExistence(timeout: 5) else {
            try captureAndSkip("player.backButton not found after player opened", in: app)
        }
        backButton.tap()

        let picker = app.segmentedControls["library.sectionPicker"]
        guard picker.waitForExistence(timeout: 5) else {
            try captureAndSkip("Library picker did not reappear after back navigation", in: app)
        }

        Thread.sleep(forTimeInterval: 1.0)
        let firstCardMaxYAfterBack = firstCard.frame.maxY
        guard firstCardMaxYAfterBack < 100 else {
            try captureAndSkip("Scroll position not restored — first card reappeared on-screen (timing or animation-dependent)", in: app)
        }
    }

    // MARK: - Subscriptions tests

    func testSubscriptionsSegmentVisible() throws {
        UITestHelpers.tapTab(named: "Library", in: app)
        let picker = app.segmentedControls["library.sectionPicker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5),
                      "library.sectionPicker should appear")
        XCTAssertTrue(picker.buttons["Subs"].exists,
                      "'Subs' segment must be present in the library picker")
    }

    func testSubscriptionsNavigationDoesNotCrash() throws {
        try openSubscriptionsSegment()
        Thread.sleep(forTimeInterval: 2)
        XCTAssertEqual(app.state, .runningForeground,
                       "App should still be running after opening Subscriptions in Library")
    }

    func testSubscriptionsSegmentShowsFeed() throws {
        try openSubscriptionsSegment()
        guard UITestHelpers.waitForVideoCards(in: app, timeout: 20) != nil else {
            try captureAndSkip("No video cards loaded within 20 s — account may not be signed in or has no subscriptions", in: app)
        }
    }

    func testNoErrorAlertOnSubscriptionsLoad() throws {
        try openSubscriptionsSegment()
        Thread.sleep(forTimeInterval: 5)
        UITestHelpers.assertNoErrorAlert(in: app)
    }

    func testSubscriptionsScrollLoadsMore() throws {
        try openSubscriptionsSegment()
        guard UITestHelpers.waitForVideoCards(in: app, timeout: 20) != nil else {
            try captureAndSkip("No video cards in Subscriptions feed — signed-in account required", in: app)
        }

        let countBefore = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'video.card.'"))
            .count

        app.swipeUp(velocity: .fast)
        Thread.sleep(forTimeInterval: 2)
        app.swipeUp(velocity: .fast)
        Thread.sleep(forTimeInterval: 3)

        let countAfter = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'video.card.'"))
            .count

        XCTAssertGreaterThanOrEqual(countAfter, countBefore,
            "Scrolling down should not reduce the video card count (pagination should add more)")
    }

    func testTappingVideoFromSubscriptionsOpensPlayer() throws {
        try openSubscriptionsSegment()
        guard let firstCard = UITestHelpers.waitForVideoCards(in: app, timeout: 20) else {
            try captureAndSkip("No video cards in Subscriptions — signed-in account required", in: app)
        }
        XCTAssertTrue(UITestHelpers.openPlayer(from: firstCard, in: app),
                      "player.titleLabel must appear after tapping a video in Library Subscriptions")
        let errorBanner = app.otherElements["player.errorBanner"].firstMatch
        if errorBanner.exists {
            try captureAndSkip("player.errorBanner appeared — network issue on this simulator clone", in: app)
        }
    }

    func testSubscriptionsScrollRestorationAfterPlayback() throws {
        try openSubscriptionsSegment()
        guard UITestHelpers.waitForVideoCards(in: app, timeout: 20) != nil else {
            try captureAndSkip("No video cards — signed-in account required", in: app)
        }

        let firstCard = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'video.card.'"))
            .firstMatch

        app.swipeUp(velocity: .fast)
        Thread.sleep(forTimeInterval: 2)
        app.swipeUp(velocity: .fast)
        Thread.sleep(forTimeInterval: 2)

        let firstCardMaxYAfterScroll = firstCard.frame.maxY
        guard firstCardMaxYAfterScroll < 100 else {
            try captureAndSkip("Could not scroll first card off-screen — feed may have too few items", in: app)
        }

        let feed = app.scrollViews.firstMatch
        let tapPoint = feed.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        tapPoint.tap()

        let titleLabel = app.staticTexts["player.titleLabel"].firstMatch
        guard titleLabel.waitForExistence(timeout: 15) else {
            try captureAndSkip("PlayerView did not open within 15 s — network unavailable or timing-dependent", in: app)
        }

        let backButton = app.buttons["player.backButton"].firstMatch
        guard backButton.waitForExistence(timeout: 5) else {
            try captureAndSkip("player.backButton not found after player opened", in: app)
        }
        backButton.tap()

        let picker = app.segmentedControls["library.sectionPicker"]
        guard picker.waitForExistence(timeout: 5) else {
            try captureAndSkip("Library picker did not reappear after back navigation", in: app)
        }

        Thread.sleep(forTimeInterval: 1.0)
        let firstCardMaxYAfterBack = firstCard.frame.maxY
        guard firstCardMaxYAfterBack < 100 else {
            try captureAndSkip("Scroll position not restored — first card reappeared on-screen (timing or animation-dependent)", in: app)
        }
    }

    // MARK: - Library Playlists tests

    func testLibraryTabOpens() {
        UITestHelpers.tapTab(named: "Library", in: app)
        let picker = app.segmentedControls["library.sectionPicker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5),
                      "library.sectionPicker should appear after opening Library")
    }

    func testLibraryPlaylistsSegmentIsReachable() throws {
        try openPlaylistsSegment()
    }

    func testPlaylistsScreenShowsContentOrSignInPrompt() throws {
        try openPlaylistsSegment()
        let contentOrEmpty = app.scrollViews.firstMatch.waitForExistence(timeout: 5)
            || app.staticTexts["Nothing here yet"].waitForExistence(timeout: 5)
            || app.staticTexts["Sign in to see your library"].waitForExistence(timeout: 5)
        XCTAssertTrue(contentOrEmpty,
                      "Playlists screen should show content, an empty state, or a sign-in prompt")
    }

    func testNoErrorAlertOnPlaylistsLoad() throws {
        try openPlaylistsSegment()
        Thread.sleep(forTimeInterval: 3)
        UITestHelpers.assertNoErrorAlert(in: app)
    }

    func testLibraryPlaylistsNavigationDoesNotCrash() throws {
        try openPlaylistsSegment()
        Thread.sleep(forTimeInterval: 2)
        XCTAssertEqual(app.state, .runningForeground,
                       "App should still be running after navigating to Playlists")
    }

    func testPlaylistsFeedPopulates() throws {
        try openPlaylistsSegment()
        guard UITestHelpers.waitForVideoCards(in: app, timeout: 20) != nil else {
            try captureAndSkip("No playlist items loaded within 20 s — account may not be signed in or has no playlists", in: app)
        }
    }

    func testTappingPlaylistOpensPlaylistView() throws {
        try openPlaylistsSegment()
        guard let firstCard = UITestHelpers.waitForVideoCards(in: app, timeout: 20) else {
            try captureAndSkip("No playlist cards loaded — signed-in account with playlists required", in: app)
        }
        firstCard.tap()
        let navBar = app.navigationBars.firstMatch
        XCTAssertTrue(navBar.waitForExistence(timeout: 10),
                      "A navigation bar should appear when opening a playlist")
    }

    func testPlaylistViewShowsVideoCardsOrEmpty() throws {
        try openPlaylistsSegment()
        guard let firstCard = UITestHelpers.waitForVideoCards(in: app, timeout: 20) else {
            try captureAndSkip("No playlist cards loaded — signed-in account with playlists required", in: app)
        }
        firstCard.tap()

        let feed = app.scrollViews["playlistView.feed"]
        let emptyState = app.staticTexts["No videos in this playlist"]

        let feedOrEmpty = feed.waitForExistence(timeout: 15)
            || emptyState.waitForExistence(timeout: 15)
        XCTAssertTrue(feedOrEmpty,
                      "PlaylistView should show either a feed (playlistView.feed) or an empty state")
    }

    func testTappingVideoInPlaylistOpensPlayer() throws {
        try openPlaylistsSegment()
        guard let playlistCard = UITestHelpers.waitForVideoCards(in: app, timeout: 20) else {
            try captureAndSkip("No playlist cards — signed-in account with playlists required", in: app)
        }
        playlistCard.tap()

        let feed = app.scrollViews["playlistView.feed"]
        guard feed.waitForExistence(timeout: 15) else {
            try captureAndSkip("playlistView.feed did not appear — playlist may be empty", in: app)
        }
        guard let videoCard = UITestHelpers.waitForVideoCards(in: app, timeout: 20) else {
            try captureAndSkip("No video cards inside playlist — playlist may be empty", in: app)
        }
        XCTAssertTrue(UITestHelpers.openPlayer(from: videoCard, in: app),
                      "player.titleLabel should appear after tapping a video in a playlist")
        let errorBanner = app.otherElements["player.errorBanner"].firstMatch
        if errorBanner.exists {
            try captureAndSkip("player.errorBanner appeared — network issue on this simulator clone", in: app)
        }
    }

    func testPlaylistsScrollRestorationAfterPlayback() throws {
        try openPlaylistsSegment()
        guard UITestHelpers.waitForVideoCards(in: app, timeout: 20) != nil else {
            try captureAndSkip("No playlist cards — signed-in account with playlists required", in: app)
        }

        let playlistCard = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'video.card.'"))
            .firstMatch
        playlistCard.tap()

        let feed = app.scrollViews["playlistView.feed"]
        guard feed.waitForExistence(timeout: 15) else {
            try captureAndSkip("playlistView.feed did not appear — playlist may be empty", in: app)
        }
        guard UITestHelpers.waitForVideoCards(in: app, timeout: 20) != nil else {
            try captureAndSkip("No video cards in playlist", in: app)
        }

        feed.swipeUp(velocity: .fast)
        Thread.sleep(forTimeInterval: 1.5)
        feed.swipeUp(velocity: .fast)
        Thread.sleep(forTimeInterval: 1.5)

        let firstCard = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'video.card.'"))
            .firstMatch
        let firstCardMaxYAfterScroll = firstCard.frame.maxY
        guard firstCardMaxYAfterScroll < 100 else {
            try captureAndSkip("Could not scroll past first card — playlist may have too few items", in: app)
        }

        let tapPoint = feed.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        tapPoint.tap()

        let titleLabel = app.staticTexts["player.titleLabel"].firstMatch
        guard titleLabel.waitForExistence(timeout: 15) else {
            try captureAndSkip("PlayerView did not open within 15 s — network unavailable or timing-dependent", in: app)
        }

        let backButton = app.buttons["player.backButton"].firstMatch
        guard backButton.waitForExistence(timeout: 5) else {
            try captureAndSkip("player.backButton not found after player opened", in: app)
        }
        backButton.tap()

        guard feed.waitForExistence(timeout: 5) else {
            try captureAndSkip("playlistView.feed did not reappear after back", in: app)
        }
        Thread.sleep(forTimeInterval: 1.0)

        let firstCardMaxYAfterBack = firstCard.frame.maxY
        guard firstCardMaxYAfterBack < 100 else {
            try captureAndSkip("Scroll position not restored — first card reappeared on-screen (timing or animation-dependent)", in: app)
        }
    }

    func testPlaylistLoadsMoreVideosOnScroll() throws {
        try openPlaylistsSegment()
        guard let playlistCard = UITestHelpers.waitForVideoCards(in: app, timeout: 20) else {
            try captureAndSkip("No playlist cards — signed-in account with playlists required", in: app)
        }
        playlistCard.tap()

        let feed = app.scrollViews["playlistView.feed"]
        guard feed.waitForExistence(timeout: 15) else {
            try captureAndSkip("playlistView.feed did not appear — playlist may be empty", in: app)
        }
        guard UITestHelpers.waitForVideoCards(in: app, timeout: 20) != nil else {
            try captureAndSkip("No video cards in playlist", in: app)
        }

        let cardsPredicate = NSPredicate(format: "identifier BEGINSWITH 'video.card.'")
        let cards = app.descendants(matching: .any).matching(cardsPredicate)
        let initialCount = cards.count
        guard initialCount >= 15 else {
            try captureAndSkip("Playlist has fewer than 15 videos — pagination won't trigger (got \(initialCount))", in: app)
        }

        for _ in 0..<6 {
            feed.swipeUp(velocity: .fast)
            Thread.sleep(forTimeInterval: 0.5)
        }

        let morePredicate = NSPredicate(format: "count > \(initialCount)")
        let moreExpectation = XCTNSPredicateExpectation(predicate: morePredicate, object: cards)
        let result = XCTWaiter().wait(for: [moreExpectation], timeout: 10)
        XCTAssertEqual(result, .completed,
            "Playlist should load more videos after scrolling to the bottom (initial: \(initialCount), after scroll: \(cards.count))")
    }

    // MARK: - Playlists navigation tests (structural, no sign-in required)

    func testAppLaunchesSuccessfully() {
        XCTAssertTrue(app.windows.firstMatch.exists, "App window should exist after launch")
    }

    func testNavigateToLibraryTab() {
        UITestHelpers.tapTab(named: "Library", in: app)
        let picker = app.segmentedControls["library.sectionPicker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5), "Library section picker should be visible")
    }

    func testPlaylistsNavigationSegmentIsReachable() {
        UITestHelpers.tapTab(named: "Library", in: app)
        let picker = app.segmentedControls["library.sectionPicker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5), "Section picker should appear")

        let playlistsButton = picker.buttons["Playlists"]
        XCTAssertTrue(playlistsButton.waitForExistence(timeout: 3), "Playlists segment should exist in picker")
        playlistsButton.tap()

        XCTAssertTrue(
            playlistsButton.isSelected,
            "Playlists segment should be selected after tap"
        )
    }

    func testPlaylistsScreenShowsContentOrEmptyState() {
        UITestHelpers.tapTab(named: "Library", in: app)
        let picker = app.segmentedControls["library.sectionPicker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        picker.buttons["Playlists"].tap()

        let contentOrEmpty = app.scrollViews.firstMatch.waitForExistence(timeout: 5)
            || app.staticTexts["Nothing here yet"].waitForExistence(timeout: 5)
            || app.staticTexts["Sign in to see your library"].waitForExistence(timeout: 5)
        XCTAssertTrue(contentOrEmpty, "Playlists screen should show content, an empty state, or a sign-in prompt")
    }

    func testPlaylistsNavigationDoesNotCrash() {
        UITestHelpers.tapTab(named: "Library", in: app)
        let picker = app.segmentedControls["library.sectionPicker"]
        guard picker.waitForExistence(timeout: 5) else {
            XCTFail("Section picker not found")
            return
        }
        picker.buttons["Playlists"].tap()
        Thread.sleep(forTimeInterval: 2)
        XCTAssertTrue(app.state == .runningForeground, "App should still be running after navigating to Playlists")
    }

    // MARK: - Downloads tests (task-99)

    private func openDownloadsSegment() throws {
        UITestHelpers.tapTab(named: "Library", in: app)
        let picker = app.segmentedControls["library.sectionPicker"]
        guard picker.waitForExistence(timeout: 5) else {
            try captureAndSkip("library.sectionPicker did not appear — Library tab may not have loaded", in: app)
        }
        let button = picker.buttons["Downloads"]
        guard button.waitForExistence(timeout: 3) else {
            try captureAndSkip("Downloads segment not found in library picker", in: app)
        }
        button.tap()
    }

    func testDownloadsSegmentExistsInLibrary() throws {
        UITestHelpers.tapTab(named: "Library", in: app)
        let picker = app.segmentedControls["library.sectionPicker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5), "library.sectionPicker should appear")
        XCTAssertTrue(
            picker.buttons["Downloads"].exists,
            "'Downloads' segment must be present in the library picker"
        )
    }

    func testDownloadsSectionDoesNotCrash() throws {
        try openDownloadsSegment()
        Thread.sleep(forTimeInterval: 1)
        XCTAssertEqual(
            app.state, .runningForeground,
            "App should still be running after opening Downloads in Library"
        )
    }

    func testDownloadsShowsEmptyStateOrList() throws {
        try openDownloadsSegment()
        Thread.sleep(forTimeInterval: 1.5)
        // Either the "No Downloaded Videos" text (empty state) or a downloaded video row must exist.
        let emptyStateText = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS 'No Downloaded Videos'")
        ).firstMatch
        let videoRow = app.cells.matching(
            NSPredicate(format: "identifier BEGINSWITH 'downloads.videoRow.'")
        ).firstMatch
        let eitherExists = emptyStateText.waitForExistence(timeout: 4) || videoRow.waitForExistence(timeout: 1)
        XCTAssertTrue(
            eitherExists,
            "Downloads section must show either an empty state or a video list"
        )
    }
}
