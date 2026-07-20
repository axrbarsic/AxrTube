import SwiftUI
import AVFoundation
import AVKit
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

// MARK: - Platform-specific AVKit / UIKit views
//
// Extracted from PlayerView.swift to keep that file under 1 000 lines.

// MARK: - FullScreenPlayerLayerView (iOS)

#if os(iOS)
/// UIViewRepresentable that embeds the shared PersistentPlayerHostView into the
/// full-screen player context. UIView.addSubview transplants the hostView from
/// the mini-player container automatically, keeping the AVPlayerLayer live.
struct FullScreenPlayerLayerView: UIViewRepresentable {
    let hostView: PersistentPlayerHostView
    var videoGravity: AVLayerVideoGravity

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .black
        container.isAccessibilityElement = false
        container.accessibilityElementsHidden = true
        hostView.videoGravity = videoGravity
        hostView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(hostView)
        NSLayoutConstraint.activate([
            hostView.topAnchor.constraint(equalTo: container.topAnchor),
            hostView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            hostView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hostView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        hostView.videoGravity = videoGravity
    }
}
#endif

// MARK: - AVPlayerLayerView

#if os(iOS) || os(tvOS)
/// Lightweight UIViewRepresentable wrapping an `AVPlayerLayer` directly.
/// Unlike `VideoPlayer` / `AVPlayerViewController`, it does not interfere
/// with the UIKit accessibility tree so SwiftUI overlays remain reachable.
/// On tvOS, `AVPlayerViewController` would provide system transport controls
/// but `AVPlayerLayer` is used here for layout consistency with iOS.
/// Named `PlayerAVLayerView` to avoid a module-level name clash with
/// `ShortsPlayerView`, which uses this type via `videoGravity: .resizeAspectFill`.
struct PlayerAVLayerView: UIViewRepresentable {
    let player: AVPlayer?
    var videoGravity: AVLayerVideoGravity = .resizeAspect
    var onLayerReady: ((AVPlayerLayer) -> Void)? = nil

    func makeUIView(context: Context) -> _PlayerUIView {
        let view = _PlayerUIView()
        view.backgroundColor = .black
        view.isAccessibilityElement = false
        view.accessibilityElementsHidden = true
        view.playerLayer.player = player
        view.playerLayer.videoGravity = videoGravity
        view.onLayerReady = onLayerReady
        return view
    }

    func updateUIView(_ uiView: _PlayerUIView, context: Context) {
        uiView.playerLayer.player = player
        uiView.playerLayer.videoGravity = videoGravity
    }

    final class _PlayerUIView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
        var onLayerReady: ((AVPlayerLayer) -> Void)?
        private var didFireCallback = false

        override func willMove(toWindow newWindow: UIWindow?) {
            super.willMove(toWindow: newWindow)
            guard newWindow != nil, !didFireCallback else { return }
            didFireCallback = true
            // Defer to next run-loop tick so the layer has a non-zero frame.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.onLayerReady?(self.playerLayer)
            }
        }
    }
}

// MARK: - PiPDelegate

/// AVPictureInPictureControllerDelegate that notifies a SwiftUI closure when
/// PiP starts or stops, and implements the restore callback required for a
/// smooth transition back to full-screen without rebuffering.
final class PiPDelegate: NSObject, AVPictureInPictureControllerDelegate {
    private let onActiveChange: (Bool) -> Void
    private let onDidStart: (() -> Void)?

    init(onActiveChange: @escaping (Bool) -> Void, onDidStart: (() -> Void)? = nil) {
        self.onActiveChange = onActiveChange
        self.onDidStart = onDidStart
    }

    func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        onDidStart?()
        onActiveChange(true)
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        onActiveChange(false)
    }

    /// Called when the user taps the PiP window to return to the app.
    /// Must call completionHandler(true) once the UI is ready to show the video
    /// again — without this iOS cannot complete the restore animation and the
    /// player rebuffers/stutters.
    func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        // The AVPlayerLayer is always present and visible in PlayerView, so the
        // UI is immediately ready. Calling completionHandler(true) right away
        // lets AVKit animate the video seamlessly back into the layer.
        completionHandler(true)
    }
}

// MARK: - HoldSpeedBadge

struct HoldSpeedBadge: View {
    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: "forward.fill")
                .font(.system(size: 20, weight: .semibold))
            Text("2×")
                .font(.system(size: 14, weight: .bold, design: .rounded))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .allowsHitTesting(false)
    }
}

// MARK: - SwipeGestureOverlay (horizontal)

#if os(iOS)
/// Left swipe → `onSwipeLeft`, right swipe → `onSwipeRight`, tap → `onTap`.
/// Set `isEnabled = false` (e.g. while the progress slider is being scrubbed) to
/// temporarily suppress pan recognition so the scrub drag is not mistaken for a swipe.
/// Named `PlayerSwipeGestureOverlay` to avoid a module-level clash with the
/// identically-structured private copy in `ShortsPlayerView.swift`.
struct PlayerSwipeGestureOverlay: UIViewRepresentable {
    var onSwipeLeft:        () -> Void
    var onSwipeRight:       () -> Void
    var onTap:              () -> Void
    var onDoubleTap:        (CGFloat) -> Void = { _ in }
    var onTwoFingerTap:     () -> Void = {}
    var onPanChanged:       ((CGFloat) -> Void)?
    var onSwipeCancelled:   (() -> Void)?
    var onLongPressStart:   (() -> Void)?
    var onLongPressEnd:     (() -> Void)?
    var onSwipeDown:        (() -> Void)? = nil
    var isEnabled:          Bool = true

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear

        let pan = UIPanGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handlePan(_:)))
        pan.cancelsTouchesInView = true
        view.addGestureRecognizer(pan)
        context.coordinator.pan = pan

        let doubleTap = UITapGestureRecognizer(target: context.coordinator,
                                               action: #selector(Coordinator.handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        doubleTap.cancelsTouchesInView = false
        doubleTap.require(toFail: pan)
        view.addGestureRecognizer(doubleTap)
        context.coordinator.doubleTap = doubleTap

        let tap = UITapGestureRecognizer(target: context.coordinator,
                                          action: #selector(Coordinator.handleTap))
        tap.cancelsTouchesInView = false
        tap.require(toFail: pan)
        tap.require(toFail: doubleTap)
        view.addGestureRecognizer(tap)
        context.coordinator.tap = tap

        let twoFingerTap = UITapGestureRecognizer(target: context.coordinator,
                                                   action: #selector(Coordinator.handleTwoFingerTap))
        twoFingerTap.numberOfTouchesRequired = 2
        twoFingerTap.cancelsTouchesInView = false
        view.addGestureRecognizer(twoFingerTap)

        let longPress = UILongPressGestureRecognizer(target: context.coordinator,
                                                      action: #selector(Coordinator.handleLongPress(_:)))
        longPress.minimumPressDuration = 0.4
        longPress.cancelsTouchesInView = false
        view.addGestureRecognizer(longPress)
        context.coordinator.longPress = longPress

        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.pan?.isEnabled = isEnabled
        context.coordinator.tap?.isEnabled = isEnabled
        context.coordinator.doubleTap?.isEnabled = isEnabled
        context.coordinator.longPress?.isEnabled = isEnabled
    }

    final class Coordinator: NSObject {
        var parent: PlayerSwipeGestureOverlay
        weak var pan: UIPanGestureRecognizer?
        weak var tap: UITapGestureRecognizer?
        weak var doubleTap: UITapGestureRecognizer?
        weak var longPress: UILongPressGestureRecognizer?
        private let minDistance: CGFloat = 40

        init(_ parent: PlayerSwipeGestureOverlay) { self.parent = parent }

        @MainActor @objc func handlePan(_ gr: UIPanGestureRecognizer) {
            let t = gr.translation(in: gr.view)
            switch gr.state {
            case .changed:
                // Only forward horizontal pan for slide-offset animation.
                if abs(t.x) >= abs(t.y) { parent.onPanChanged?(t.x) }
            case .ended:
                // Swipe-down: vertical-dominant, downward, meets threshold → minimize
                if abs(t.y) > minDistance, t.y > 0, abs(t.y) > abs(t.x) {
                    parent.onSwipeCancelled?() // reset any horizontal offset
                    parent.onSwipeDown?()
                    return
                }
                guard abs(t.x) > minDistance, abs(t.x) > abs(t.y) else {
                    parent.onSwipeCancelled?()
                    return
                }
                if t.x < 0 { parent.onSwipeLeft() } else { parent.onSwipeRight() }
            case .cancelled, .failed:
                parent.onSwipeCancelled?()
            default:
                break
            }
        }

        @MainActor @objc func handleTap() { parent.onTap() }
        @MainActor @objc func handleDoubleTap(_ gr: UITapGestureRecognizer) {
            let width = gr.view?.bounds.width ?? 1
            let normalizedX = width > 0 ? gr.location(in: gr.view).x / width : 0.5
            parent.onDoubleTap(normalizedX)
        }
        @MainActor @objc func handleTwoFingerTap() { parent.onTwoFingerTap() }

        @MainActor @objc func handleLongPress(_ gr: UILongPressGestureRecognizer) {
            switch gr.state {
            case .began:
                parent.onLongPressStart?()
            case .ended, .cancelled, .failed:
                parent.onLongPressEnd?()
            default:
                break
            }
        }
    }
}
#endif // os(iOS)
#endif // os(iOS) || os(tvOS)

// MARK: - PlayerNSLayerView (macOS)

#if os(macOS)
/// NSViewRepresentable wrapping an AVPlayerLayer directly — the AppKit
/// equivalent of PlayerAVLayerView on iOS/tvOS.
struct PlayerNSLayerView: NSViewRepresentable {
    let player: AVPlayer?
    var videoGravity: AVLayerVideoGravity = .resizeAspect

    func makeNSView(context: Context) -> _PlayerNSView {
        let view = _PlayerNSView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = videoGravity
        return view
    }

    func updateNSView(_ nsView: _PlayerNSView, context: Context) {
        nsView.playerLayer.player = player
        nsView.playerLayer.videoGravity = videoGravity
    }

    final class _PlayerNSView: NSView {
        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer = AVPlayerLayer()
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

        override func layout() {
            super.layout()
            playerLayer.frame = bounds
        }
    }
}
#endif
