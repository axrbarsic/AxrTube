#if os(iOS)
import SwiftUI
import WebKit
import iPocketTubeCore

// MARK: - TOSMiniPlayerView
//
// Compact playback bar shown at the bottom of MainTabView when the TOS player
// has been minimized (TOSPlayerStateStore.presentation == .miniPlayer).
//
// Layout: [ ▶/⏸ ] [ thumbnail + title ] [ ✕ ]
//
// Actions:
//   play/pause button → vm.play() / vm.pause()
//   tap bar (thumbnail / title) → tosState.expand() → re-presents TOSPlayerView
//   ✕ button → tosState.stop() → releases WKWebView, hides mini-player

struct TOSMiniPlayerView: View {
    @Environment(TOSPlayerStateStore.self) private var tosState

    var body: some View {
        let isPlaying = tosState.vm?.playerState == .playing || tosState.vm?.playerState == .buffering
        NowPlayingAccessoryChrome(
            title: tosState.currentVideo?.title ?? "Текущее видео",
            isPlaying: isPlaying,
            canTogglePlayback: tosState.vm != nil,
            openDetails: {
                iPocketTubeHaptics.shared.perform(.contentSelection)
                tosState.expand()
            },
            togglePlayback: {
                iPocketTubeHaptics.shared.perform(.playbackTransport)
                if isPlaying {
                    tosState.vm?.pause()
                } else {
                    tosState.vm?.play()
                }
            },
            close: {
                iPocketTubeHaptics.shared.perform(.primaryAction)
                tosState.stop()
            }
        ) {
            Group {
                if let webView = tosState.vm?.webView {
                    // The same WKWebView remains attached while playback is minimized.
                    TOSMiniPlayerLayerView(webView: webView)
                } else if let thumb = tosState.currentVideo?.thumbnailURL {
                    AsyncImage(url: thumb) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().scaledToFill()
                        default:
                            Color.gray.opacity(0.3)
                        }
                    }
                } else {
                    ZStack {
                        Color.secondary.opacity(0.16)
                        Image(systemName: "waveform")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

// MARK: - TOSMiniPlayerLayerView

/// UIViewRepresentable that hosts the TOS player's WKWebView as a live thumbnail.
/// UIView.addSubview transplants the webView from the full-screen
/// YouTubeWebPlayerView's container automatically — no explicit removeFromSuperview
/// needed. Keeping the webView attached to the window keeps the embedded YouTube
/// <video> element's document.visibilityState == 'visible', so playback continues
/// while minimized. Mirrors MiniPlayerLayerView's transplant pattern for AVPlayer.
private struct TOSMiniPlayerLayerView: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .black
        container.clipsToBounds = true
        attach(to: container)
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        if webView.superview !== uiView {
            attach(to: uiView)
        }
    }

    private func attach(to container: UIView) {
        // Disable interaction so taps fall through to the SwiftUI buttons
        // (expand / play-pause / close) overlaying this view, rather than being
        // captured by YouTube's native player controls inside the WKWebView.
        webView.isUserInteractionEnabled = false
        webView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
    }
}
#endif // os(iOS)
