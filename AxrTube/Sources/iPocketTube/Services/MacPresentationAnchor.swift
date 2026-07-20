#if os(macOS)
import AppKit
import AuthenticationServices

// MARK: - MacPresentationAnchor
//
// Satisfies ASWebAuthenticationPresentationContextProviding so that
// ASWebAuthenticationSession can attach its in-app browser sheet to the
// active macOS window.  Used by SignInView on macOS only.

final class MacPresentationAnchor: NSObject, ASWebAuthenticationPresentationContextProviding,
                                    @unchecked Sendable {

    static let shared = MacPresentationAnchor()
    private override init() { super.init() }

    /// Captured at the point the user taps "Open Activation Page" — guaranteed to
    /// be a valid, on-screen window.  Used as the first candidate so the sheet has
    /// a stable anchor even after the app loses key-window status (e.g. while Safari
    /// is open in the foreground).
    weak var capturedWindow: NSWindow?

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        // Prefer the window we captured at call time; fall back through progressively
        // broader lookups.  Creating a bare NSWindow() as a last resort caused crashes
        // when AppKit tried to animate the sheet on an orphaned, off-screen window, so
        // we avoid that entirely — if no real window is found we return windows.first
        // (which always exists while the app is running).
        capturedWindow
            ?? NSApplication.shared.keyWindow
            ?? NSApplication.shared.mainWindow
            ?? NSApplication.shared.windows.first(where: { !($0 is NSPanel) && $0.isVisible })
            ?? NSApplication.shared.windows.first
            ?? NSWindow()
    }
}
#endif
