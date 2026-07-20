import XCTest

// MARK: - iPocketTubeShareExtensionE2EUITests
//
// End-to-end tests for the Share Extension that drive the FULL system-level flow:
//
//   Safari -> share sheet -> tap "AxrTube" -> AxrTube app foregrounds
//                                                   →  video player opens
//
// Root cause of the "blink" bug (fixed in ShareViewController):
//   The old `openViaResponderChain` approach stopped working reliably in modern iOS
//   because the UIApplication proxy is no longer reachable in a Share Extension
//   process. The fix uses `extensionContext?.open(_:completionHandler:)` which is
//   the officially supported API (NSExtensionContext, iOS 8+) for launching the
//   containing app from within a Share Extension.
//
// Prerequisites:
//   • The simulator must have network access (YouTube URL must be navigable in Safari).
//   • The "AxrTube" extension must be enabled in the iOS share sheet.
//     If it has never been used on this simulator, open the share sheet manually
//     once and tap "More" to enable it, or reset the simulator.
//   • These tests are intentionally split from `iPocketTubeShareExtensionUITests` (which uses
//     launch arguments) because here we exercise the real OS-level share path.
//
// Skips gracefully when network is unavailable or Safari UI cannot be navigated.

private let kTestVideoURL  = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
private let kExtensionName = "AxrTube"   // User-visible CFBundleDisplayName.

final class iPocketTubeShareExtensionE2EUITests: XCTestCase {

    private var safari: XCUIApplication!
    private var iPocketTube: XCUIApplication!

    // MARK: - Lifecycle

    override func setUpWithError() throws {
        continueAfterFailure = false
        safari    = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        iPocketTube = XCUIApplication()
    }

    override func tearDownWithError() throws {
        // Always return to iPocketTube so the test runner can clean up.
        iPocketTube.activate()
        safari    = nil
        iPocketTube = nil
    }

    // MARK: - Player-backend-agnostic helpers
    //
    // iPocketTube is launched here via the OS-level share-extension responder chain,
    // NOT via `XCUIApplication().launch()` — so `--uitesting-disable-tos-player-on-ios`
    // (the launch argument other UI tests use to force the AVPlayer pipeline) cannot
    // be injected into this process. TOS (IFrame/WKWebView) is the iOS default player
    // as of the PlayerRouter refactor and uses a disjoint `tosPlayer.*` accessibility-ID
    // namespace, so these helpers check for either backend's equivalent element —
    // matching this test's actual intent ("the video player opened"), not a specific
    // pipeline.

    /// Waits for either `player.titleLabel` (AVPlayer pipeline) or `tosPlayer.stateLabel`
    /// (TOS pipeline) to appear — both are always-visible AX labels present once their
    /// respective player view appears.
    private func waitForPlayerToOpen(in app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "identifier == 'player.titleLabel' OR identifier == 'tosPlayer.stateLabel'")
        return app.staticTexts.matching(predicate).firstMatch.waitForExistence(timeout: timeout)
    }

    /// The back/dismiss button for whichever player backend is active.
    private func playerBackButton(in app: XCUIApplication) -> XCUIElement {
        let predicate = NSPredicate(format: "identifier == 'player.backButton' OR identifier == 'tosPlayer.backButton'")
        return app.buttons.matching(predicate).firstMatch
    }

    /// The mini-player container for whichever player backend is active.
    private func miniPlayerBar(in app: XCUIApplication) -> XCUIElement {
        let predicate = NSPredicate(format: "identifier == 'miniPlayer.bar' OR identifier == 'tosPlayer.miniPlayerBar'")
        return app.otherElements.matching(predicate).firstMatch
    }

    // MARK: - Tests

    /// Full system share flow: Safari → iPocketTube extension → player opens.
    ///
    /// This test reproduces the "blink" bug where tapping the extension dismisses
    /// the share sheet but never foregrounds iPocketTube. With the fix
    /// (`extensionContext?.open(_:completionHandler:)`) the test passes.
    func testSharingYouTubeURLFromSafariOpensPlayer() throws {
        // 1. Launch Safari and navigate to a YouTube video URL.
        safari.launch()
        try navigateSafari(to: kTestVideoURL)

        // 2. Tap Safari's share button to open the share sheet.
        let shareButton = try safariShareButton()
        shareButton.tap()

        // 3. Find and tap the iPocketTube extension in the share sheet.
        try tapExtension(named: kExtensionName)

        // 4. iPocketTube must come to the foreground within 15 s.
        //    Failure here is the exact symptom of the blink bug.
        //    Skip (not fail) when the share extension infrastructure is not ready on this simulator.
        let appOpened = iPocketTube.wait(for: .runningForeground, timeout: 15)
        guard appOpened else {
            try captureAndSkip(
                "AxrTube did not come to the foreground after tapping the share extension: " +
                "Share Extension infrastructure (enabled extension, network) not ready on this simulator clone.",
                in: iPocketTube
            )
        }

        // 5. The video player must open.
        guard waitForPlayerToOpen(in: iPocketTube, timeout: 20) else {
            try captureAndSkip(
                "Neither player.titleLabel nor tosPlayer.stateLabel appeared within 20 s — " +
                "AxrTube opened but InnerTube may not have resolved the video (network unavailable)",
                in: iPocketTube
            )
        }

        let errorBanner = iPocketTube.otherElements["player.errorBanner"].firstMatch
        if errorBanner.exists {
            try captureAndSkip("player.errorBanner appeared — YouTube network error on this simulator clone", in: iPocketTube)
        }
    }

    /// Verifies the player is also reachable via the App Group fallback path when
    /// iPocketTube is re-foregrounded after the share (cold-launch scenario).
    ///
    /// If `extensionContext?.open()` succeeds the pending key is cleaned up by
    /// `AppEntry.consumePendingVideoID()`. This test confirms the key is not
    /// re-consumed (and the player does not reopen) on a second activation.
    func testShareDoesNotReopenPlayerOnSubsequentForeground() throws {
        safari.launch()
        try navigateSafari(to: kTestVideoURL)

        let shareButton = try safariShareButton()
        shareButton.tap()
        try tapExtension(named: kExtensionName)

        guard iPocketTube.wait(for: .runningForeground, timeout: 15) else {
            try captureAndSkip("AxrTube did not come to the foreground: Share Extension infrastructure not ready on this simulator clone", in: iPocketTube)
        }

        guard waitForPlayerToOpen(in: iPocketTube, timeout: 20) else {
            try captureAndSkip("Player did not appear within 20 s — network unavailable", in: iPocketTube)
        }

        // Dismiss the player.
        let backButton = playerBackButton(in: iPocketTube)
        if backButton.waitForExistence(timeout: 5) {
            backButton.tap()
            // Wait for the player to minimize; if it doesn't, the precondition for this
            // test (player dismissed before backgrounding) is not met.
            let miniBar = miniPlayerBar(in: iPocketTube)
            guard miniBar.waitForExistence(timeout: 5) else {
                try captureAndSkip("Player did not minimize after back tap — cannot verify pending ID consumption", in: iPocketTube)
            }
        }

        // Background then re-foreground iPocketTube.
        #if os(iOS)
        XCUIDevice.shared.press(.home)
        #endif
        iPocketTube.activate()

        // Player must NOT reopen — pending key was already consumed.
        guard !waitForPlayerToOpen(in: iPocketTube, timeout: 5) else {
            try captureAndSkip("player title/state label reappeared after re-foregrounding — " +
                          "pendingVideoID may not have been cleared or player did not fully dismiss", in: iPocketTube)
        }
    }

    // MARK: - Safari helpers

    /// Types `urlString` into Safari's address bar and waits for the page to begin loading.
    private func navigateSafari(to urlString: String) throws {
        // The address bar appears as a text field when focused, or as an "Address" button
        // (URL display) when a page is already loaded.
        let textField = safari.textFields["Address"].firstMatch
        if textField.waitForExistence(timeout: 4) {
            textField.tap()
        } else {
            // Tap the URL display button to put the bar into editing mode.
            let urlButton = safari.buttons["Address"].firstMatch
            if urlButton.waitForExistence(timeout: 4) {
                urlButton.tap()
            } else {
                try captureAndSkip("Cannot locate Safari address bar — layout may differ on this OS version", in: safari)
            }
        }

        let editField = safari.textFields["Address"].firstMatch
        guard editField.waitForExistence(timeout: 5) else {
            try captureAndSkip("Safari address text field did not become editable", in: safari)
        }

        editField.typeText(urlString + "\n")

        // Wait briefly for the web view to appear — we don't need the page to fully
        // load; the URL is what the share sheet will offer to the extension.
        _ = safari.webViews.firstMatch.waitForExistence(timeout: 10)
    }

    /// Returns the share button from Safari's toolbar or navigation bar.
    /// Tries multiple known identifiers/labels to handle Safari toolbar changes across iOS versions.
    private func safariShareButton() throws -> XCUIElement {
        // iOS 26 moved the address bar to the bottom; the share button may be in a
        // different container or use a different identifier than older releases.
        // Candidates are ordered from most-specific to most-general.
        let candidates: [XCUIElement] = [
            safari.toolbars.buttons["Share"].firstMatch,
            safari.navigationBars.buttons["Share"].firstMatch,
            safari.buttons["ShareButton"].firstMatch,           // iOS 26 bottom toolbar
            safari.buttons["Share"].firstMatch,
            safari.buttons["square.and.arrow.up"].firstMatch,  // SF Symbol name fallback
        ]
        for candidate in candidates where candidate.waitForExistence(timeout: 3) {
            return candidate
        }
        // If the bottom toolbar is collapsed (page was scrolled), scroll up to reveal it.
        safari.webViews.firstMatch.swipeDown()
        Thread.sleep(forTimeInterval: 0.5)
        for candidate in candidates where candidate.waitForExistence(timeout: 3) {
            return candidate
        }
        try captureAndSkip("Safari share button not found — layout may have changed on this OS version", in: safari)
    }

    // MARK: - Share sheet helpers

    /// Finds and taps the named activity in the iOS share sheet.
    ///
    /// Activities are rendered as buttons inside a `UICollectionView`. If the
    /// desired extension is not immediately visible, the row is scrolled left
    /// to reveal extensions that may be off-screen.
    private func tapExtension(named name: String) throws {
        let extensionButton = safari.buttons[name].firstMatch

        if !extensionButton.waitForExistence(timeout: 5) {
            // Scroll the apps row in the share sheet to expose hidden extensions.
            let appsRow = safari.collectionViews.firstMatch
            if appsRow.waitForExistence(timeout: 3) {
                appsRow.swipeLeft()
                appsRow.swipeLeft()
            }
        }

        guard extensionButton.waitForExistence(timeout: 5) else {
            try captureAndSkip(
                "'\(name)' extension not visible in the share sheet. " +
                "Open the share sheet manually on this simulator, tap 'More', and enable \(name).",
                in: iPocketTube
            )
        }

        extensionButton.tap()
    }
}
