import SwiftUI
import AVFoundation
import iPocketTubeCore
#if canImport(UIKit)
import UIKit
#endif

// MARK: - ShortsPlayerView
//
// Full-screen vertical-swipe player for YouTube Shorts.
// Swipe up advances to the next short; swipe down goes to the previous one.
//
// AVPlayerViewController intercepts all UIKit touches before SwiftUI sees them,
// so a plain SwiftUI DragGesture layered above VideoPlayer is never delivered.
// Instead, a UIViewRepresentable installs a UIPanGestureRecognizer directly
// into the window that is set to cancel the AVPlayer's own recognizers, giving
// SwiftUI-side navigation full priority.

public struct ShortsPlayerView: View {
    public let startIndex: Int
    @State var videos: [Video]
    #if os(iOS)
    @State var vm: ShortsEmbedPlayerViewModel
    /// Pre-warmed VM for Short N+1. Loaded in the background while Short N plays
    /// so swipe-to-next has no black-screen delay. Swapped into `vm` by `goTo(_:)`
    /// when the user swipes up and the standby is ready.
    @State var standbyVM: ShortsEmbedPlayerViewModel? = nil
    /// The just-retired Short N-1, kept alive (paused, not stopped) instead of
    /// torn down on every forward swipe — so swipe-DOWN (backward) is also
    /// instant, mirroring `standbyVM`'s forward case. Without this, backward
    /// navigation always cold-reloads; if the user swipes back faster than a
    /// cold reload can finish, every swipe interrupts the last one before it
    /// ever paints a frame, producing a run of black screens. See #277.
    @State var previousVM: ShortsEmbedPlayerViewModel? = nil
    #else
    @State var vm: PlaybackViewModel
    #endif
    @State var currentIndex: Int
    @Environment(\.dismiss) var dismiss
    @Environment(\.scenePhase) var scenePhase
    @Environment(SettingsStore.self) var store
    @Environment(AuthService.self) var authService
    @State var slideOffset: CGFloat = 0
    @State var isTransitioning = false
    @State var isFetchingMore = false
    /// True while the app is backgrounded — guards onDisappear from calling stop()
    /// when iOS fires it as a side-effect of backgrounding rather than navigation.
    @State var isInBackground = false
    let api: InnerTubeAPI

    public init(videos: [Video], startIndex: Int = 0, api: InnerTubeAPI) {
        self.startIndex = startIndex
        self.api = api
        self._videos = State(initialValue: videos)
        self._currentIndex = State(initialValue: startIndex)
        #if os(iOS)
        self._vm = State(initialValue: ShortsEmbedPlayerViewModel(api: api))
        #else
        self._vm = State(initialValue: PlaybackViewModel(api: api))
        #endif
    }

    public var body: some View {
        NavigationStack {
        ZStack {
            Color.black.ignoresSafeArea()

            #if os(iOS)
            // Size the embed to its natural 9:16 aspect ratio and center it in the
            // screen, so equal blank margins appear above and below the video. This
            // moves the native HTML5 controls away from the very bottom edge.
            GeometryReader { geo in
                let videoH = min(geo.size.height, geo.size.width * 16.0 / 9.0)
                ZStack {
                    // Color.clear fills the ZStack to the full screen so the inner
                    // views are centered; allowsHitTesting(false) keeps it passthrough.
                    Color.clear.allowsHitTesting(false)
                    ShortsTOSWebView(vm: vm)
                        .frame(width: geo.size.width, height: videoH)
                        .accessibilityHidden(true)
                    // Currently unreachable: goTo(_:) no longer ever promotes standbyVM
                    // (the WKWebView-reparenting bug in #279 made that path unfixable
                    // here), so prewarmStandby is never called and this never becomes
                    // non-nil. Left in place, off-screen rather than near-zero-opacity
                    // (an earlier attempt — opacity made WebKit deprioritize the video
                    // compositor and never properly reinstate it after a reparent), in
                    // case the underlying bug is fixed and this is revisited. See #279.
                    if let standby = standbyVM {
                        ShortsTOSWebView(vm: standby)
                            .frame(width: geo.size.width, height: videoH)
                            .offset(y: geo.size.height * 3)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                    // Host the retired-but-cached Short N-1's WKWebView the same way —
                    // same constraints as standbyVM. See #277/#279.
                    if let previous = previousVM {
                        ShortsTOSWebView(vm: previous)
                            .frame(width: geo.size.width, height: videoH)
                            .offset(y: geo.size.height * 3)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                    // Cover the video area (not the margins) while the new embed loads.
                    if !vm.isReady {
                        Color.black
                            .frame(width: geo.size.width, height: videoH)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                            .accessibilityIdentifier("shorts.loadingCover")
                    }
                }
            }
            .ignoresSafeArea()
            #else
            if ProcessInfo.processInfo.arguments.contains("--uitesting") {
                Color.black.ignoresSafeArea()
            } else {
                #if os(tvOS)
                // PlayerAVLayerView instead of VideoPlayer/AVPlayerViewController.
                // Using AVPlayerViewController (VideoPlayer) causes it to dominate
                // the entire UIKit accessibility tree, hiding all overlaid SwiftUI
                // elements (index badge, controls). A bare AVPlayerLayer renders
                // video without any UIKit accessibility interference.
                PlayerAVLayerView(player: vm.player, videoGravity: .resizeAspectFill)
                    .ignoresSafeArea()
                    .accessibilityHidden(true)
                #else
                Color.black.ignoresSafeArea()
                #endif
            }
            #endif

            // Gesture capture layer — a UIViewRepresentable that installs a
            // UIPanGestureRecognizer at the UIKit level so it fires even when
            // AVPlayerViewController is absorbing touches below.
            #if os(iOS)
            SwipeGestureOverlay(
                onSwipeUp: {
                    guard !isTransitioning else { return }
                    if let next = ShortsNavigation.targetIndex(vertical: -100, horizontal: 0, current: currentIndex, count: videos.count) {
                        iPocketTubeHaptics.shared.perform(.contentSelection)
                        performVerticalTransition(direction: -1) { goTo(next) }
                    } else {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { slideOffset = 0 }
                    }
                },
                onSwipeDown: {
                    guard !isTransitioning else { return }
                    if let prev = ShortsNavigation.targetIndex(vertical: 100, horizontal: 0, current: currentIndex, count: videos.count) {
                        iPocketTubeHaptics.shared.perform(.contentSelection)
                        performVerticalTransition(direction: 1) { goTo(prev) }
                    } else {
                        loadMoreAtStart()
                    }
                },
                onTap: { point in
                    // Native controls occupy the bottom ~12% of the screen (the HTML5
                    // controls bar at the bottom of the 9:16 embed). Taps there are
                    // passed through to WKWebView when paused so native controls work.
                    // Taps anywhere above that: toggle play/pause regardless of state.
                    let screenH = UIScreen.main.bounds.height
                    let inNativeControlsArea = point.y / screenH > 0.88
                    if vm.playerState == .paused && inNativeControlsArea { return }
                    iPocketTubeHaptics.shared.perform(.playbackTransport)
                    vm.togglePlayPause()
                },
                onTwoFingerTap: {},
                onPanChanged: { dy in
                    guard !isTransitioning else { return }
                    let canGoUp   = ShortsNavigation.targetIndex(vertical: -100, horizontal: 0, current: currentIndex, count: videos.count) != nil
                    let canGoDown = ShortsNavigation.targetIndex(vertical:  100, horizontal: 0, current: currentIndex, count: videos.count) != nil
                    if (dy < 0 && canGoUp) || (dy > 0 && canGoDown) {
                        slideOffset = dy
                    } else {
                        slideOffset = dy * 0.15  // rubber-band resistance at boundaries
                    }
                },
                onSwipeCancelled: {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { slideOffset = 0 }
                }
            )
            .ignoresSafeArea()
            .accessibilityHidden(true)
            #endif

            #if !os(iOS)
            if vm.isLoading {
                VStack(spacing: 12) {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.white)
                        .scaleEffect(1.5)
                    if let msg = vm.retryStatusMessage {
                        Text(msg)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.75))
                            .transition(.opacity)
                            .animation(.easeInOut(duration: 0.3), value: vm.retryStatusMessage)
                    }
                }
                .transition(.opacity)
                .animation(.easeInOut(duration: 0.2), value: vm.isLoading)
            }

            // Stats for Nerds overlay (toggled by two-finger tap)
            if vm.statsForNerdsVisible {
                StatsForNerdsOverlay(snapshot: vm.statsSnapshot)
                    .transition(.opacity)
                    .animation(.easeInOut(duration: 0.2), value: vm.statsForNerdsVisible)
            }
            #endif
        }
        // Single-tap always toggles play/pause via the UIKit window-level tap
        // recognizer inside SwipeGestureOverlay (onTap above). WKWebView absorbs
        // UIKit touches before this SwiftUI view sees them, so .onTapGesture here
        // would never fire — the window-level path is the only reliable one.
        .offset(y: slideOffset)
        .background(Color.black.ignoresSafeArea())
        #if os(tvOS)
        // Siri Remote D-pad: up/down navigate prev/next short.
        .onMoveCommand { direction in
            guard !isTransitioning else { return }
            switch direction {
            case .up:
                if let next = ShortsNavigation.targetIndex(vertical: -100, horizontal: 0, current: currentIndex, count: videos.count) {
                    performVerticalTransition(direction: -1) { goTo(next) }
                }
            case .down:
                if let prev = ShortsNavigation.targetIndex(vertical: 100, horizontal: 0, current: currentIndex, count: videos.count) {
                    performVerticalTransition(direction: 1) { goTo(prev) }
                }
            default:
                vm.toggleControls()
            }
        }
        #endif
        // indexBadge, controls overlay, and error banner are placed OUTSIDE the
        // ZStack as overlays so UIViewRepresentable elements (SwipeGestureOverlay)
        // inside the ZStack cannot absorb them from the accessibility tree.
        .overlay(alignment: .topTrailing) {
            indexBadge
        }
        .overlay {
            if shouldShowControlsOverlay {
                shortsOverlay
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("shorts.controlsOverlay")
                    .transition(.opacity)
                    .animation(.easeInOut(duration: 0.2), value: shouldShowControlsOverlay)
            }
        }
        .overlay {
            #if os(iOS)
            if let msg = vm.errorMessage {
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.white)
                    .padding(12)
                    .background(.black.opacity(0.6))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .accessibilityIdentifier("shorts.errorBanner")
            }
            #else
            if let err = vm.error {
                Text(err.localizedDescription)
                    .font(.caption)
                    .foregroundStyle(.white)
                    .padding(12)
                    .background(.black.opacity(0.6))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .accessibilityIdentifier("shorts.errorBanner")
            }
            #endif
        }
        .overlay(alignment: .bottomTrailing) {
            if isFetchingMore {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(.white)
                    .padding(12)
                    .background(.black.opacity(0.4))
                    .clipShape(Circle())
                    .padding(.bottom, 60)
                    .padding(.trailing, 20)
                    .transition(.opacity)
            }
        }
        #if os(iOS)
        .navigationBarHidden(true)
        .statusBarHidden(true)
        .toolbar(.hidden, for: .tabBar)
        #endif
        .ignoresSafeArea()
        .onAppear {
            if vm.currentVideoId == videos[currentIndex].id {
                if vm.wasPlayingBeforeSuspend { vm.resume() }
            } else {
                loadVideo(at: currentIndex)
            }
            if ProcessInfo.processInfo.arguments.contains("--uitesting-show-controls") {
                vm.showControls()
                vm.cancelControlsHide()
            }
        }
        .onDisappear {
            guard !isInBackground else { return }
            vm.stop()
            #if os(iOS)
            previousVM?.stop()
            #endif
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                isInBackground = true
                vm.handleBackground()
            case .active:
                isInBackground = false
                vm.handleForeground()
            default:
                break
            }
        }
        #if os(iOS)
        .onChange(of: vm.playerState) { _, newState in
            if newState == .ended {
                handleShortEnded()
            } else if newState == .playing {
                // Restart auto-hide timer so controls fade out 3s after playback resumes.
                vm.showControls()
            }
        }
        .onChange(of: vm.playerError) { _, newError in
            if newError != nil {
                advanceAfterError()
            }
        }
        #endif
        } // NavigationStack
    }

    private var shouldShowControlsOverlay: Bool {
        vm.controlsVisible
    }
}
