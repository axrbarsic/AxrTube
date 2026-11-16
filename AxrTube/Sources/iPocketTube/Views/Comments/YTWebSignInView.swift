#if os(iOS)
import SwiftUI
import WebKit
import iPocketTubeCore

/// «Вход для комментариев»: Google's own sign-in page in an isolated web
/// view. The app never sees the password; once youtube.com sets the session
/// cookies they are captured, stored in the Keychain and the page closes.
struct YTWebSignInView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var auth = WebCommentAuth.shared
    @State private var captured = false

    var body: some View {
        NavigationStack {
            ZStack {
                if captured {
                    VStack(spacing: 14) {
                        ProgressView()
                        Text("Проверяю вход…").foregroundStyle(YTColor.secondaryText)
                    }
                } else {
                    GoogleSignInWebView { session in
                        captured = true
                        Task {
                            await auth.signedIn(with: session)
                            dismiss()
                        }
                    }
                    .ignoresSafeArea(edges: .bottom)
                }
            }
            .navigationTitle("Вход для комментариев")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
            }
        }
    }
}

private struct GoogleSignInWebView: UIViewRepresentable {
    let onSignedIn: (YouTubeWebSession) -> Void

    static let startURL = URL(string:
        "https://accounts.google.com/ServiceLogin?service=youtube&hl=ru&passive=true&continue="
        + "https%3A%2F%2Fwww.youtube.com%2Fsignin%3Faction_handle_signin%3Dtrue%26app%3Ddesktop%26hl%3Dru%26next%3D%252F"
    )!
    /// Safari on iPhone: Google refuses sign-in from browsers it does not know.
    static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Mobile/15E148 Safari/604.1"

    func makeCoordinator() -> Coordinator { Coordinator(onSignedIn: onSignedIn) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // Isolated from the app's other web views; cookies end up in the Keychain.
        config.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: config)
        view.customUserAgent = Self.userAgent
        view.navigationDelegate = context.coordinator
        view.load(URLRequest(url: Self.startURL))
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let onSignedIn: (YouTubeWebSession) -> Void
        private var done = false

        init(onSignedIn: @escaping (YouTubeWebSession) -> Void) {
            self.onSignedIn = onSignedIn
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard !done, let host = webView.url?.host, host.hasSuffix("youtube.com") else { return }
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
                guard let self, !self.done else { return }
                var values: [String: String] = [:]
                for cookie in cookies where cookie.domain.hasSuffix("youtube.com") {
                    values[cookie.name] = cookie.value
                }
                let session = YouTubeWebSession(cookies: values)
                guard session.isSignedIn else { return }
                self.done = true
                DispatchQueue.main.async { self.onSignedIn(session) }
            }
        }
    }
}
#endif
