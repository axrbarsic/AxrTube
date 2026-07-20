import SwiftUI
import os
#if canImport(UIKit)
import UIKit
#endif

private let swipeLog = Logger(subsystem: "com.void.ipockettube.app", category: "TOSSwipe")

// MARK: - TOSSwipeNavigationOverlay
//
// Horizontal swipe-left/right navigation for the TOS (WKWebView) player —
// mirrors PlayerSwipeGestureOverlay's left/right behaviour for the AVPlayer
// pipeline (PlayerView+AVLayer.swift: left → playNext(), right → playPrevious()).
//
// Reuses PassthroughGestureView (SwipeGestureOverlay.swift) so the pan gesture
// recognizer is re-homed onto the window and never blocks touches to the
// WKWebView's own controls. To avoid stealing YouTube's native bottom
// scrubber/control-bar drag (which also uses horizontal pans for seeking),
// `gestureRecognizer(_:shouldReceive:)` only accepts touches starting in the
// top `verticalActivationFraction` of the screen.

#if os(iOS)
struct TOSSwipeNavigationOverlay: UIViewRepresentable {
    var onSwipeLeft: () -> Void
    var onSwipeRight: () -> Void
    /// Called on any tap anywhere on the player. Receives window coordinates so
    /// the caller can distinguish tap zones (e.g. native controls area at bottom).
    var onTap: ((CGPoint) -> Void)? = nil
    var isEnabled: Bool = true
    /// Touches below this fraction of the screen height are ignored, leaving
    /// YouTube's bottom scrubber/control-bar free to handle horizontal drags.
    var verticalActivationFraction: CGFloat = 0.75

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> PassthroughGestureView {
        let view = PassthroughGestureView()
        view.backgroundColor = .clear

        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePan(_:)))
        pan.cancelsTouchesInView = false
        pan.delegate = context.coordinator
        context.coordinator.pan = pan

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        tap.cancelsTouchesInView = false
        tap.delegate = context.coordinator
        context.coordinator.tap = tap

        view.managedGestureRecognizers = [pan, tap]
        return view
    }

    func updateUIView(_ uiView: PassthroughGestureView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.pan?.isEnabled = isEnabled
        context.coordinator.tap?.isEnabled = isEnabled
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: TOSSwipeNavigationOverlay
        weak var pan: UIPanGestureRecognizer?
        weak var tap: UITapGestureRecognizer?
        private let minDistance: CGFloat = 40

        init(_ parent: TOSSwipeNavigationOverlay) {
            self.parent = parent
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                                shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            true
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            // Pan only fires in the top verticalActivationFraction of the screen.
            // Tap fires everywhere — no vertical restriction.
            guard gestureRecognizer === pan else { return true }
            let window = (gestureRecognizer.view as? UIWindow) ?? gestureRecognizer.view?.window
            guard let window else { return true }
            let y = touch.location(in: window).y
            let fraction = parent.verticalActivationFraction
            let accept = y <= window.bounds.height * fraction
            swipeLog.debug("[shouldReceive] y=\(Int(y)) height=\(Int(window.bounds.height)) fraction=\(fraction, format: .fixed(precision: 2)) → \(accept ? "accept" : "reject")")
            return accept
        }

        @MainActor @objc func handleTap(_ gr: UITapGestureRecognizer) {
            parent.onTap?(gr.location(in: nil))
        }

        @MainActor @objc func handlePan(_ gr: UIPanGestureRecognizer) {
            let t = gr.translation(in: gr.view)
            swipeLog.notice("[handlePan] state=\(gr.state.rawValue) tx=\(Int(t.x)) ty=\(Int(t.y))")
            guard gr.state == .ended else { return }
            guard abs(t.x) > minDistance, abs(t.x) > abs(t.y) else {
                swipeLog.notice("[handlePan] ended — ignored (tx=\(Int(t.x)) ty=\(Int(t.y)) minDist=\(Int(self.minDistance)))")
                return
            }
            let dir = t.x < 0 ? "LEFT" : "RIGHT"
            swipeLog.notice("[handlePan] swipe \(dir) confirmed (tx=\(Int(t.x)))")
            if t.x < 0 {
                parent.onSwipeLeft()
            } else {
                parent.onSwipeRight()
            }
        }
    }
}
#endif
