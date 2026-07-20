#if os(iOS)
import SwiftUI
import WebKit

/// Hosts the persistent `WKWebView` owned by `ShortsEmbedPlayerViewModel` inside the
/// SwiftUI view hierarchy. The view model owns the WKWebView instance for the
/// lifetime of a `ShortsPlayerView` session (one WKWebView reused across many
/// `loadShort(video:)` calls, per the design spec's swipe-latency decision); this
/// representable just attaches it to the container view with Auto Layout
/// constraints — mirrors `TOSPlayerView.swift`'s `YouTubeWebPlayerView`
/// (TOSPlayerView.swift:544-572) and Task 1's `SpikeWebView`.
struct ShortsTOSWebView: UIViewRepresentable {
    let vm: ShortsEmbedPlayerViewModel

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .black
        attach(to: container)
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        if vm.webView.superview !== uiView {
            // Remove the previously attached WKWebView before adding the new one.
            // On a standby swap, the old webView is still a subview of the container;
            // without this, both the old and new webViews end up stacked in the container.
            uiView.subviews.forEach { $0.removeFromSuperview() }
            attach(to: uiView)
        }
    }

    private func attach(to container: UIView) {
        let webView = vm.webView
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.isUserInteractionEnabled = true
        webView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
    }
}
#endif
