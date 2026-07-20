import SwiftUI

// MARK: - ScrollOffsetPreferenceKey

/// Reports the current vertical scroll offset from inside a `ScrollView`.
/// Use by placing a zero-height `GeometryReader` inside the ScrollView's content and
/// reading changes via `.onPreferenceChange(ScrollOffsetPreferenceKey.self)`.
struct ScrollOffsetPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

// MARK: - ScrollOffsetRestorer

/// A zero-size `UIViewRepresentable` that restores the scrollable offset of the nearest
/// ancestor `UIScrollView` once, then calls `onComplete`.
///
/// Always keep this view in the content (don't add/remove conditionally — that would
/// trigger a layout recalculation that resets `contentOffset`). Pass `nil` when no
/// restore is needed; the view becomes a no-op.
///
/// ```swift
/// // In the ScrollView content (unconditionally):
/// ScrollOffsetRestorer(targetOffset: restoreOffset) { restoreOffset = nil }
///     .frame(width: 0, height: 0)
/// ```
// MARK: - ScrollOffsetStore

/// Reference-type container that captures a weak reference to the nearest
/// ancestor `UIScrollView`. All access must happen on the main thread / actor.
#if os(iOS) || os(tvOS)
final class ScrollOffsetStore: @unchecked Sendable {
    weak var scrollView: UIScrollView?
}
#else
final class ScrollOffsetStore: @unchecked Sendable {}
#endif

// MARK: - ScrollOffsetReader

/// A zero-size `UIViewRepresentable` that finds the nearest ancestor `UIScrollView`
/// and stores a weak reference in a `ScrollOffsetStore`, deferred to the next
/// run-loop tick so the UIView is fully inserted into the hierarchy before the
/// walk-up starts.
///
/// Place unconditionally inside the `ScrollView` content.
///
/// ```swift
/// @State private var scrollStore = ScrollOffsetStore()
///
/// ScrollView {
///     ScrollOffsetReader(store: scrollStore).frame(width: 0, height: 0)
/// }
/// // In onDisappear (always on @MainActor) — read live offset before the view
/// // leaves the window:
/// savedOffset = scrollStore.scrollView?.contentOffset.y ?? 0
/// ```
#if os(iOS) || os(tvOS)
struct ScrollOffsetReader: UIViewRepresentable {
    let store: ScrollOffsetStore

    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.isHidden = true
        return v
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        // Short-circuit if we already have a live reference.
        guard store.scrollView == nil else { return }
        // Defer to the next run-loop tick so the UIView has been inserted into its
        // parent hierarchy before we try to walk up to the UIScrollView.
        DispatchQueue.main.async { [weak uiView] in
            guard let uiView, store.scrollView == nil else { return }
            var cursor: UIView? = uiView.superview
            while let current = cursor {
                if let sv = current as? UIScrollView {
                    store.scrollView = sv
                    return
                }
                cursor = current.superview
            }
        }
    }
}
#endif

// MARK: - ScrollOffsetRestorer

#if os(iOS) || os(tvOS)
struct ScrollOffsetRestorer: UIViewRepresentable {
    /// Desired `contentOffset.y`. Pass `nil` to do nothing.
    let targetOffset: CGFloat?
    let onComplete: () -> Void

    func makeUIView(context: Context) -> UIView {
        UIView()  // zero-size, hidden
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        guard let offset = targetOffset else { return }
        // Defer past the current SwiftUI layout commit AND any UIKit navigation
        // pop animation, so contentSize is finalised and contentOffset is stable.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            var current: UIView? = uiView.superview
            while let view = current {
                if let sv = view as? UIScrollView {
                    // With a VStack (all items rendered) contentSize is already full;
                    // no clamping needed — but guard against negative offset.
                    let y = max(offset, 0)
                    sv.setContentOffset(CGPoint(x: 0, y: y), animated: false)
                    self.onComplete()
                    return
                }
                current = view.superview
            }
        }
    }
}
#endif
