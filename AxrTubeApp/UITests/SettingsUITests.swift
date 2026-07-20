import XCTest

// MARK: - SettingsUITests
//
// All tests except testSignInButtonVisibleWhenSignedOut have moved to
// HomeFeedAndSettingsUITests.swift (combined with HomeFeedNoDuplicatesUITests
// for a single shared app launch).
//
// testSignInButtonVisibleWhenSignedOut is kept here because it deliberately
// terminates and re-launches the app with --uitesting-sign-out and cannot
// share state with other tests.

final class SettingsUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["--uitesting", "--uitesting-reset-settings"]
        app.launch()
    }

    override func tearDownWithError() throws {
        app = nil
    }

    func testSignInButtonVisibleWhenSignedOut() throws {
        app.terminate()
        app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--uitesting-reset-settings", "--uitesting-sign-out"]
        app.launch()
        UITestHelpers.tapTab(named: "Settings", in: app)
        let signInPredicate = NSPredicate(format: "identifier == 'settings.signInButton' OR label == 'Sign in with Google'")
        let signInEl = app.descendants(matching: .any).matching(signInPredicate).firstMatch
        XCTAssertTrue(signInEl.waitForExistence(timeout: 5),
                      "'Sign in with Google' button must be visible when the session is cleared via --uitesting-sign-out")
    }
}
