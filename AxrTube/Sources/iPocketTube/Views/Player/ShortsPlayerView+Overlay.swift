import SwiftUI
import iPocketTubeCore

extension ShortsPlayerView {

    // MARK: - Always-visible index badge
    //
    // Rendered outside the ZStack (as an .overlay on the body) so UIViewRepresentable
    // elements inside the ZStack cannot absorb it from the accessibility tree.

    var indexBadge: some View {
        Text("\(currentIndex + 1) / \(videos.count)")
            .font(.caption)
            .foregroundStyle(.white.opacity(0.8))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.black.opacity(0.4))
            .clipShape(Capsule())
            .accessibilityIdentifier("shorts.indexLabel")
            .padding(.top, 12)
            .padding(.trailing, 20)
    }

    // MARK: - Overlay

    // When paused, the SwiftUI overlay must NOT use .contentShape(Rectangle()).
    // That modifier makes the full-screen UIHostingView the UIKit hit-test target,
    // blocking every touch from reaching the native HTML5 video controls inside
    // WKWebView. Without .contentShape, only the back button (which has a visible
    // background) is hit-testable; touches anywhere else fall through to WKWebView.
    // Swipe navigation while paused is handled by the window-level UIPanGestureRecognizer
    // in SwipeGestureOverlay, which fires regardless of which UIView owns the touch.

    @ViewBuilder
    var shortsOverlay: some View {
        #if os(iOS)
        // When paused, skip .contentShape so the UIHostingView doesn't intercept UIKit
        // touches in the transparent Spacer region — native controls need direct delivery.
        // Swipe navigation while paused is handled by the window-level UIPanGestureRecognizer
        // in SwipeGestureOverlay (fires regardless of which UIView owns the touch).
        if vm.playerState == .paused {
            overlayStack
        } else {
            overlayStack
                .contentShape(Rectangle())
                .simultaneousGesture(overlaySwipeGesture)
        }
        #else
        // tvOS: no playerState on PlaybackViewModel, no DragGesture; contentShape for
        // D-pad focus but no swipe gesture (navigation via .onMoveCommand instead).
        overlayStack
            .contentShape(Rectangle())
        #endif
    }

    private var overlayStack: some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    iPocketTubeHaptics.shared.perform(.primaryAction)
                    dismiss()
                } label: {
                    Image(systemName: AppSymbol.chevronLeft)
                        .font(.title2)
                        .foregroundStyle(.white)
                        .padding(12)
                        .background(.black.opacity(0.4))
                        .clipShape(Circle())
                }
                .accessibilityIdentifier("shorts.backButton")
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)

            Spacer()
        }
        // Play/pause taps are handled by the window-level UITapGestureRecognizer in
        // SwipeGestureOverlay (onTap: { vm.togglePlayPause() }). A SwiftUI
        // .onTapGesture here would never fire — WKWebView absorbs UIKit touches
        // before the hosting UIView's gesture recognizers see them.
    }

    // Swipe navigation gesture applied to the overlay when playing (contentShape active).
    // tvOS has no DragGesture — handled via .onMoveCommand in ShortsPlayerView.
    #if !os(tvOS)
    private var overlaySwipeGesture: some Gesture {
        DragGesture(minimumDistance: 50, coordinateSpace: .global)
            .onEnded { value in
                guard !isTransitioning else { return }
                let dy = value.translation.height
                guard abs(dy) > abs(value.translation.width) else { return }
                if dy < 0 {
                    if let next = ShortsNavigation.targetIndex(
                        vertical: -100, horizontal: 0,
                        current: currentIndex, count: videos.count
                    ) {
                        performVerticalTransition(direction: -1) { goTo(next) }
                    } else {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { slideOffset = 0 }
                    }
                } else {
                    if let prev = ShortsNavigation.targetIndex(
                        vertical: 100, horizontal: 0,
                        current: currentIndex, count: videos.count
                    ) {
                        performVerticalTransition(direction: 1) { goTo(prev) }
                    } else {
                        loadMoreAtStart()
                    }
                }
            }
    }
    #endif
}
