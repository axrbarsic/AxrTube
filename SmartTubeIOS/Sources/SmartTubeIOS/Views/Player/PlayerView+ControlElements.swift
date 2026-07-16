import SwiftUI
import AVFoundation
import AVKit
import SmartTubeIOSCore
#if canImport(UIKit)
import UIKit
#endif

private let controlsLog = CrashlyticsLogger(category: "Player")

// MARK: - PlayerControlsOverlay
//
// Dedicated view for the interactive transport controls overlaid on the player.
// Extracted from PlayerView.body to reduce the compiled function size and
// the Swift generic type tree depth in __swift5_typeref.

struct PlayerControlsOverlay: View {
    let size: CGSize
    let safeAreaInsets: EdgeInsets
    let video: Video
    let controlScale: CGFloat
    @Binding var showMoreMenu: Bool
    @Binding var channelDestination: ChannelDestination?

    #if os(iOS)
    @Binding var pipController: AVPictureInPictureController?
    @Binding var isPiPActive: Bool
    @Binding var isLandscapeLocked: Bool
    @Environment(PlayerStateStore.self) private var playerState
    var vm: PlaybackViewModel { playerState.vm }
    #else
    let vm: PlaybackViewModel
    #endif
    #if !os(tvOS)
    @Binding var showQualityPicker: Bool
    @Binding var showSpeedPicker: Bool
    @Binding var showAudioTrackPicker: Bool
    @Binding var showSleepTimerPicker: Bool
    #endif
    #if os(tvOS)
    @Binding var highlightedControl: PlayerView.TVPlayerControl?
    #endif
    @Environment(SettingsStore.self) var store
    @Environment(\.dismiss) var dismiss
    var body: some View {
        VStack {
            // Top bar: back + title
            HStack {
                Button {
                    #if os(iOS)
                    if store.settings.miniPlayerEnabled { playerState.minimize() } else { playerState.stop() }
                    #else
                    vm.stop(); withAnimation(.none) { dismiss() }
                    #endif
                } label: {
                    Image(systemName: AppSymbol.chevronLeft)
                        .font(.title2)
                        .foregroundStyle(.white)
                        .padding(12)
                        .background(.black.opacity(0.4))
                        .clipShape(Circle())
                }
                .accessibilityIdentifier("player.backButton")
                #if os(tvOS)
                .buttonStyle(.plain)
                .scaleEffect(highlightedControl == .back ? 1.5 : 1.0)
                .shadow(color: highlightedControl == .back ? .white.opacity(0.85) : .clear, radius: 12)
                .animation(.easeInOut(duration: 0.15), value: highlightedControl)
                #endif
                VStack(alignment: .leading, spacing: 2) {
                    Text(vm.playerInfo?.video.title ?? video.title)
                        .font(.headline)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .accessibilityIdentifier("player.titleLabel")
                    let channelId = vm.playerInfo?.video.channelId ?? video.channelId
                    let channelTitle = vm.playerInfo?.video.channelTitle ?? video.channelTitle
                    Button {
                        guard let cid = channelId, !cid.isEmpty else { return }
                        #if os(iOS)
                        // PlayerView is presented via fullScreenCover — there is no
                        // NavigationStack, so setting channelDestination is a no-op.
                        // Post the shared notification instead (same path as VideoCardView),
                        // then dismiss the player so the parent can push ChannelView.
                        NotificationCenter.default.post(
                            name: .openChannel,
                            object: nil,
                            userInfo: ["channelId": cid]
                        )
                        dismiss()
                        #else
                        channelDestination = ChannelDestination(channelId: cid)
                        #endif
                    } label: {
                        Text(channelTitle)
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.8))
                            .lineLimit(1)
                    }
                    #if os(tvOS)
                    .buttonStyle(.plain)
                    .scaleEffect(highlightedControl == .channel ? 1.5 : 1.0)
                    .shadow(color: highlightedControl == .channel ? .white.opacity(0.85) : .clear, radius: 12)
                    .animation(.easeInOut(duration: 0.15), value: highlightedControl)
                    #else
                    .buttonStyle(.plain)
                    #endif
                    .accessibilityIdentifier("player.channelName")
                    .disabled(channelId == nil || channelId?.isEmpty == true)
                }
                Spacer()
                #if os(iOS)
                // Picture-in-Picture button — shown when PiP is enabled in settings and supported on this device
                if store.settings.pipEnabled, let pip = pipController {
                    Button {
                        if isPiPActive {
                            pip.stopPictureInPicture()
                        } else {
                            pip.startPictureInPicture()
                        }
                    } label: {
                        Image(systemName: isPiPActive ? "pip.exit" : "pip.enter")
                            .font(.system(size: 18 * controlScale))
                            .foregroundStyle(.white)
                            .padding(8)
                            .background(.black.opacity(0.4))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("player.pipButton")
                }
                // AirPlay route picker
                AirPlayRoutePickerView()
                    .frame(width: 40, height: 40)
                    .accessibilityIdentifier("player.airPlayButton")
                #endif
                // Share / Download menu
                Button {
                    controlsLog.notice("[menu] ... button tapped — controlsVisible=\(vm.controlsVisible) showMoreMenu=\(showMoreMenu)")
                    showMoreMenu = true
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 18 * controlScale))
                        .foregroundStyle(.white)
                        .padding(8)
                        .background(.black.opacity(0.4))
                        .clipShape(Circle())
                }
                .accessibilityIdentifier("player.moreButton")
                #if os(tvOS)
                .buttonStyle(.plain)
                .scaleEffect(highlightedControl == .more ? 1.5 : 1.0)
                .shadow(color: highlightedControl == .more ? .white.opacity(0.85) : .clear, radius: 12)
                .animation(.easeInOut(duration: 0.15), value: highlightedControl)
                #else
                .buttonStyle(.plain)
                #endif
            }
            .padding(.horizontal, 20)
            #if os(tvOS)
            .padding(.top, 0)
            #else
            .padding(.top, max(safeAreaInsets.top, 20))
            #endif

            Spacer()

            // Centre: rewind / play-pause / forward
            HStack(spacing: 40) {
                #if os(tvOS)
                seekButton(symbol: "gobackward.\(store.settings.seekBackSeconds)",
                           seconds: -Double(store.settings.seekBackSeconds),
                           tvHighlighted: highlightedControl == .seekBack)
                #else
                seekButton(symbol: "gobackward.\(store.settings.seekBackSeconds)",
                           seconds: -Double(store.settings.seekBackSeconds))
                #endif
                playPauseButton
                #if os(tvOS)
                seekButton(symbol: "goforward.\(store.settings.seekForwardSeconds)",
                           seconds: Double(store.settings.seekForwardSeconds),
                           tvHighlighted: highlightedControl == .seekForward)
                #else
                seekButton(symbol: "goforward.\(store.settings.seekForwardSeconds)",
                           seconds: Double(store.settings.seekForwardSeconds))
                #endif
            }
            .disabled(vm.isLoading)
            .opacity(vm.isLoading ? 0.3 : 1)

            Spacer()

            // Bottom: progress bar + prev/next
            VStack(spacing: 8) {
                // Current chapter title — shown whenever chapters are available
                if let chapter = vm.currentChapter {
                    Text(chapter.title)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.white.opacity(0.9))
                        .padding(.horizontal, 20)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .transition(.opacity)
                        .animation(.easeInOut(duration: 0.2), value: chapter.title)
                }
                progressBar
                #if !os(tvOS)
                quickAccessButtonRow
                #endif
                HStack {
                    // Previous video button
                    Button {
                        vm.playPrevious()
                    } label: {
                        Image(systemName: AppSymbol.previousTrack)
                            .font(.system(size: 18 * controlScale))
                            .foregroundStyle(vm.hasPrevious && !vm.isLoading ? .white : .white.opacity(0.3))
                            #if os(iOS)
                            .padding(8)
                            .background(.black.opacity(0.4))
                            .clipShape(Circle())
                            #endif
                    }
                    .buttonStyle(.plain)
                    #if os(tvOS)
                    .focusable(false)
                    .scaleEffect(highlightedControl == .prevVideo ? 1.55 : 1.0)
                    .shadow(color: highlightedControl == .prevVideo ? .white.opacity(0.85) : .clear, radius: 14)
                    .animation(.easeInOut(duration: 0.15), value: highlightedControl)
                    #endif
                    .disabled(!vm.hasPrevious || vm.isLoading)
                    .accessibilityIdentifier("player.prevBtn")

                    // Previous chapter button — only present when the video has chapters
                    if !vm.chapters.isEmpty {
                        Button {
                            vm.skipToPreviousChapter()
                        } label: {
                            Image(systemName: AppSymbol.previousChapter)
                                .font(.system(size: 18 * controlScale))
                                .foregroundStyle(vm.hasPreviousChapter && !vm.isLoading ? .white : .white.opacity(0.3))
                        }
                        .buttonStyle(.plain)
                        #if os(tvOS)
                        .focusable(false)
                        .scaleEffect(highlightedControl == .prevChapter ? 1.55 : 1.0)
                        .shadow(color: highlightedControl == .prevChapter ? .white.opacity(0.85) : .clear, radius: 14)
                        .animation(.easeInOut(duration: 0.15), value: highlightedControl)
                        #endif
                        .disabled(!vm.hasPreviousChapter || vm.isLoading)
                        .accessibilityIdentifier("player.prevChapterBtn")
                    }

                    #if !os(tvOS)
                    Text(formatDuration(vm.currentTime))
                        .padding(.leading, 6)
                        .accessibilityIdentifier("player.currentTimeLabel")
                    Spacer()
                    Text(formatDuration(vm.duration))
                        .padding(.trailing, 6)
                        .accessibilityIdentifier("player.durationLabel")
                    #else
                    Spacer()
                    #endif

                    // Next chapter button — only present when the video has chapters
                    if !vm.chapters.isEmpty {
                        Button {
                            vm.skipToNextChapter()
                        } label: {
                            Image(systemName: AppSymbol.nextChapter)
                                .font(.system(size: 18 * controlScale))
                                .foregroundStyle(vm.hasNextChapter && !vm.isLoading ? .white : .white.opacity(0.3))
                        }
                        .buttonStyle(.plain)
                        #if os(tvOS)
                        .focusable(false)
                        .scaleEffect(highlightedControl == .nextChapter ? 1.55 : 1.0)
                        .shadow(color: highlightedControl == .nextChapter ? .white.opacity(0.85) : .clear, radius: 14)
                        .animation(.easeInOut(duration: 0.15), value: highlightedControl)
                        #endif
                        .disabled(!vm.hasNextChapter || vm.isLoading)
                        .accessibilityIdentifier("player.nextChapterBtn")
                    }

                    #if os(iOS)
                    // Landscape lock button
                    Button {
                        isLandscapeLocked.toggle()
                    } label: {
                        Image(systemName: isLandscapeLocked ? "lock.rotation" : "lock.rotation.open")
                            .font(.system(size: 18 * controlScale))
                            .foregroundStyle(.white)
                            .padding(8)
                            .background(.black.opacity(0.4))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("player.landscapeLockButton")

                    // Audio-only button
                    Button {
                        vm.toggleAudioOnlyLive()
                        store.settings.audioOnlyMode = vm.isAudioOnlyMode
                    } label: {
                        Image(systemName: store.settings.audioOnlyMode ? "video" : AppSymbol.audioOnly)
                            .font(.system(size: 18 * controlScale))
                            .foregroundStyle(store.settings.audioOnlyMode ? Color.accentColor : .white)
                            .padding(8)
                            .background(.black.opacity(0.4))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("player.audioOnlyButton")
                    #endif

                    // Next video button
                    Button {
                        vm.playNext()
                    } label: {
                        Image(systemName: AppSymbol.nextTrack)
                            .font(.system(size: 18 * controlScale))
                            .foregroundStyle(vm.hasNext ? .white : .white.opacity(0.3))
                            #if os(iOS)
                            .padding(8)
                            .background(.black.opacity(0.4))
                            .clipShape(Circle())
                            #endif
                    }
                    .buttonStyle(.plain)
                    #if os(tvOS)
                    .focusable(false)
                    .scaleEffect(highlightedControl == .nextVideo ? 1.55 : 1.0)
                    .shadow(color: highlightedControl == .nextVideo ? .white.opacity(0.85) : .clear, radius: 14)
                    .animation(.easeInOut(duration: 0.15), value: highlightedControl)
                    #endif
                    .disabled(!vm.hasNext)
                    .accessibilityIdentifier("player.nextBtn")
                }
                .font(.caption)
                .foregroundStyle(.white.opacity(0.8))
                #if os(tvOS)
                .padding(.horizontal, 40)
                #else
                .padding(.horizontal, 20)
                #endif
            }
            .padding(.bottom, 20)
        }
        .background(
            LinearGradient(
                colors: [.black.opacity(0.6), .clear, .clear, .black.opacity(0.6)],
                startPoint: .top,
                endPoint: .bottom
            )
            .contentShape(Rectangle())
            .onTapGesture {
                controlsLog.notice("[menu] gradient background tap — controlsVisible=\(vm.controlsVisible)")
                vm.toggleControls()
            }
        )
        #if os(tvOS)
        // Controls overlay is not a focus section — the outer view handles all input.
        .onTapGesture { vm.toggleControls() }
        #endif
    }
}

// MARK: - Control element views

extension PlayerControlsOverlay {

    // MARK: - Play / Pause

    var playPauseButton: some View {
        Button { vm.togglePlayPause() } label: {
            Image(systemName: vm.videoEnded ? "arrow.counterclockwise" : (vm.isPlaying ? "pause.fill" : "play.fill"))
                // .original preserves the white foreground on tvOS even when the focus
                // engine or button state tries to apply a system tint colour.
                .renderingMode(.original)
                .font(.system(size: 42 * controlScale))
                .foregroundStyle(.white)
                #if !os(tvOS)
                .padding(12)
                #endif
        }
        .buttonStyle(.plain)
        .smartTubeEDRPressEffect(
            enabled: store.settings.experimentalEDRPressGlowEnabled,
            cornerRadius: 32 * controlScale
        )
        #if !os(tvOS)
        .contentShape(Rectangle())
        #endif
        #if os(tvOS)
        .focusable(false)
        .scaleEffect(highlightedControl == .playPause ? 1.6 : 1.0)
        .shadow(color: highlightedControl == .playPause ? .white.opacity(0.65) : .clear, radius: 8)
        .animation(.easeInOut(duration: 0.15), value: highlightedControl)
        #endif
        .accessibilityIdentifier("player.playPauseButton")
    }

    // MARK: - Seek buttons

    func seekButton(symbol: String, seconds: TimeInterval, tvHighlighted: Bool = false) -> some View {
        Button { vm.seekRelative(seconds: seconds) } label: {
            Image(systemName: symbol)
                // .original preserves the white foreground on tvOS — prevents system
                // tinting from turning the icon into a white rectangle when highlighted.
                .renderingMode(.original)
                .font(.system(size: 28 * controlScale))
                .foregroundStyle(.white)
                #if !os(tvOS)
                .padding(12)
                #endif
        }
        .buttonStyle(.plain)
        #if !os(tvOS)
        .contentShape(Rectangle())
        #endif
        #if os(tvOS)
        .focusable(false)
        .scaleEffect(tvHighlighted ? 1.55 : 1.0)
        .shadow(color: tvHighlighted ? .white.opacity(0.6) : .clear, radius: 7)
        .animation(.easeInOut(duration: 0.15), value: tvHighlighted)
        #endif
    }

    // MARK: - Progress bar

    var progressBar: some View {
        #if os(tvOS)
        tvProgressBar
        #else
        iosProgressBar
        #endif
    }

    var iosProgressBar: some View {
        // Wrap in an outer GeometryReader so the highPriorityGesture below can
        // reference the bar's width.  The gesture is placed on the full-height
        // VStack (tooltip row + track row = 60 pt) so any touch in that area —
        // including the 28 pt invisible tooltip strip above the visible bar — will
        // activate the scrub drag.  Previously the gesture was only on the inner
        // 28 pt track ZStack, which meant touches on the empty tooltip row were
        // silently swallowed without triggering the seek.
        GeometryReader { outerGeo in
            let hPad: CGFloat = 20
            let trackW = outerGeo.size.width - hPad * 2

            VStack(spacing: 4) {
                // Tooltip row — always occupies space so layout doesn't jump
                GeometryReader { geo in
                    if vm.isScrubbing && vm.duration > 0 {
                        let fraction = CGFloat(vm.scrubTime / vm.duration)
                        let thumbX = hPad + trackW * fraction
                        let chapterAtScrub = vm.chapters.last(where: { $0.startTime <= vm.scrubTime })
                        let labelW: CGFloat = chapterAtScrub != nil ? min(outerGeo.size.width * 0.5, 180) : 64
                        let clampedX = min(max(thumbX, hPad + labelW / 2), outerGeo.size.width - hPad - labelW / 2)

                        VStack(spacing: 2) {
                            if let chapter = chapterAtScrub {
                                Text(chapter.title)
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(.white.opacity(0.85))
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                            Text(formatDuration(vm.scrubTime))
                                .font(.caption.monospacedDigit())
                                .fontWeight(.semibold)
                                .foregroundStyle(.white)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 6))
                        .frame(width: labelW)
                        .position(x: clampedX, y: geo.size.height / 2)
                    }
                }
                .frame(height: 28)

                // Track + slider row (custom — fully transparent thumb and track)
                GeometryReader { geo in
                    let time = vm.isScrubbing ? vm.scrubTime : vm.currentTime
                    let progress = vm.duration > 0 ? CGFloat(time / vm.duration) : 0
                    let thumbX = hPad + trackW * progress

                    ZStack {
                        // Background track
                        Capsule()
                            .fill(Color.white.opacity(0.2))
                            .frame(height: 4)
                            .padding(.horizontal, hPad)

                        // Progress fill
                        HStack(spacing: 0) {
                            Capsule()
                                .fill(Color.red.opacity(0.5))
                                .frame(width: max(thumbX - hPad, 0), height: 4)
                            Spacer(minLength: 0)
                        }
                        .padding(.leading, hPad)

                        // Thumb
                        Circle()
                            .fill(Color.white.opacity(0.5))
                            .frame(width: 16, height: 16)
                            .position(x: thumbX, y: geo.size.height / 2)
                    }
                    .overlay(sponsorBlockMarkers)
                    .overlay(chapterMarkers)
                }
                .frame(height: 28)
            }
            .contentShape(Rectangle())
            #if !os(tvOS)
            // highPriorityGesture on the full VStack (tooltip + track, 60 pt total)
            // ensures the seek-bar drag beats any child-view tap gestures (e.g.
            // chapter-marker hit areas) and activates even when the touch lands on
            // the invisible tooltip strip above the visible progress bar.
            .highPriorityGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let fraction = min(max((value.location.x - hPad) / trackW, 0), 1)
                        if !vm.isScrubbing { vm.beginScrubbing() }
                        vm.updateScrub(to: Double(fraction) * vm.duration)
                    }
                    .onEnded { _ in vm.commitScrub() }
            )
            #endif
        }
        .frame(height: 60)
        .accessibilityIdentifier("player.progressBar")
    }

    // Chapter tick marks on the progress bar — small white notches at each chapter boundary.
    // Each tick has a 24×44 pt transparent tap area so the user can tap to jump to it.
    var chapterMarkers: some View {
        GeometryReader { geo in
            let hPad: CGFloat = 20
            let trackW = geo.size.width - hPad * 2
            ForEach(vm.chapters) { chapter in
                let x = hPad + trackW * CGFloat(chapter.startTime / max(vm.duration, 1))
                ZStack {
                    // Invisible enlarged hit area
                    Color.clear
                        .frame(width: 24, height: 44)
                    // Visible tick
                    Rectangle()
                        .fill(Color.white.opacity(0.85))
                        .frame(width: 2, height: 12)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    guard !vm.isScrubbing else { return }
                    vm.seek(to: chapter.startTime)
                }
                .position(x: x, y: geo.size.height / 2)
            }
        }
    }

    // SponsorBlock segment markers on the progress bar
    var sponsorBlockMarkers: some View {
        GeometryReader { geo in
            let hPad: CGFloat = 20
            let trackW = geo.size.width - hPad * 2
            ForEach(vm.sponsorSegments) { seg in
                let x = hPad + trackW * CGFloat(seg.start / max(vm.duration, 1))
                let w = trackW * CGFloat((seg.end - seg.start) / max(vm.duration, 1))
                Rectangle()
                    .fill(seg.category.color.opacity(0.8))
                    .frame(width: max(w, 2), height: 4)
                    .position(x: x + w / 2, y: geo.size.height / 2)
            }
        }
    }
}

// MARK: - Slide transition + toast/error (PlayerView extension)

extension PlayerView {

    // MARK: - Slide transition

    /// Animates the current content off-screen in `direction` (-1 = left, +1 = right),
    /// runs `action` to load the next/previous video, then slides the new content in
    /// from the opposite side.
    func performHorizontalTransition(direction: CGFloat, screenWidth: CGFloat, action: @escaping () -> Void) {
        // Set the re-entry guard synchronously so any concurrent gesture event
        // arriving before the Task runs still sees isTransitioning == true.
        isTransitioning = true
        // Defer ALL SwiftUI state mutations (incl. the initial slide-out animation)
        // into the async Task so none of them execute synchronously inside UIKit's
        // touch-event delivery pass. On iOS 26 the UpdateCycle framework throws when
        // @Observable/@State mutations happen synchronously during event dispatch.
        Task { @MainActor in
            withAnimation(.easeIn(duration: 0.2)) {
                slideOffset = direction * screenWidth
            }
            try? await Task.sleep(for: .milliseconds(220))
            action()                                        // load new video, clears AVPlayer
            slideOffset = -direction * screenWidth          // snap to opposite side (off-screen)
            withAnimation(.easeOut(duration: 0.25)) {
                slideOffset = 0                             // slide new content in
            }
            try? await Task.sleep(for: .milliseconds(270))
            isTransitioning = false
        }
    }

    // MARK: - Toast / error

    var sponsorSkipToast: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                if let seg = vm.currentToastSegment {
                    Button("Skip \(seg.category.displayName)") {
                        vm.skipToastSegment()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(seg.category.color)
                    #if os(tvOS)
                    // When the skip-toast button is focused, D-pad left/right must still
                    // seek. Without this modifier the move event is consumed by the button
                    // and the ConditionalMoveCommand on the player body never fires
                    // (it is intentionally disabled while the toast is active so that the
                    // focus engine can see the button). Adding onMoveCommand here gives
                    // the button a way to pass the direction through to seeking.
                    .onMoveCommand { direction in
                        switch direction {
                        case .left:  vm.seekRelative(seconds: -Double(store.settings.seekBackSeconds))
                        case .right: vm.seekRelative(seconds: Double(store.settings.seekForwardSeconds))
                        default: break
                        }
                    }
                    .focused($skipToastButtonFocused)
                    #endif
                    .padding()
                    .transition(.move(edge: .trailing))
                }
            }
        }
        .animation(.easeInOut, value: vm.currentToastSegment?.id)
    }

    // Returns true when the error is an IP/VPN block (APIError.ipBlocked).
    // Extracted to a separate function so the Swift type-checker does not have to
    // resolve a closure-in-body pattern while simultaneously inferring `some View`.
    private func isIPBlockError(_ err: Error) -> Bool {
        if let apiError = err as? APIError, case .ipBlocked = apiError { return true }
        return false
    }

    // Returns true when the error requires the user to sign in (APIError.signInRequired).
    // Retrying is futile — show a "Sign In" button instead of "Try Again".
    private func isSignInRequiredError(_ err: Error) -> Bool {
        if let apiError = err as? APIError, case .signInRequired = apiError { return true }
        return false
    }

    @ViewBuilder
    func errorBanner(_ err: Error) -> some View {
        // IP-block errors show a specific message and no retry button — retrying
        // with the same IP will also fail and may extend the YouTube block duration.
        let isIPBlock = isIPBlockError(err)
        let isSignInRequired = isSignInRequiredError(err)
        VStack(spacing: 12) {
            HStack {
                Image(systemName: AppSymbol.warning)
                    .foregroundStyle(.yellow)
                Text(err.localizedDescription)
                    .font(.callout)
                    .foregroundStyle(.white)
            }
            if !isIPBlock && !isSignInRequired {
                Button {
                    vm.retryLoad()
                } label: {
                    Text("Try Again")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                        .background(Color.white)
                        .clipShape(Capsule())
                }
                .accessibilityIdentifier("player.retryButton")
            }
            if isSignInRequired {
                SignInButtonView()
            }
        }
        .padding()
        .background(.black.opacity(0.75))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .padding()
        .accessibilityIdentifier(isIPBlock ? "player.ipBlockBanner" : "player.errorBanner")
    }
}

#if !os(tvOS)
// MARK: - Quick-access row (iOS and macOS)
//
// Compact pill buttons giving one-tap access to speed, quality, audio track,
// and sleep-timer pickers without opening the 3-dot more menu.
// Surfaced directly below the progress bar as requested in GitHub issue #52.
extension PlayerControlsOverlay {

    @ViewBuilder var quickAccessButtonRow: some View {
        HStack(spacing: 8) {
            quickAccessButton(
                systemImage: "speedometer",
                label: speedLabel,
                accessibilityId: "player.quickAccess.speed"
            ) { showSpeedPicker = true }

            if !vm.isAudioOnlyMode {
                quickAccessButton(
                    systemImage: "film.stack",
                    label: qualityLabel,
                    accessibilityId: "player.quickAccess.quality"
                ) { showQualityPicker = true }
                .disabled(vm.availableFormats.isEmpty)
                .opacity(vm.availableFormats.isEmpty ? 0.4 : 1)
            }

            if vm.availableAudioTracks.count > 1 {
                quickAccessButton(
                    systemImage: "waveform",
                    label: audioTrackLabel,
                    accessibilityId: "player.quickAccess.audioTrack"
                ) { showAudioTrackPicker = true }
            }

            quickAccessButton(
                systemImage: "moon.zzz",
                label: sleepTimerLabel,
                accessibilityId: "player.quickAccess.sleepTimer"
            ) { showSleepTimerPicker = true }
        }
        .padding(.horizontal, 20)
        .padding(.top, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("player.quickAccessRow")
    }

    // MARK: - Quick-access label helpers

    private var speedLabel: String {
        store.settings.playbackSpeed == 1.0 ? "Normal"
            : String(format: "%.2g", store.settings.playbackSpeed) + "×"
    }

    private var qualityLabel: String {
        vm.selectedFormat?.qualityLabel
            ?? (vm.pendingQualityLabel.isEmpty ? "Auto" : vm.pendingQualityLabel)
    }

    private var audioTrackLabel: String {
        vm.selectedAudioTrack.map { $0.languageCode } ?? "Auto"
    }

    private var sleepTimerLabel: String {
        vm.sleepTimerMinutes.map { "\($0) min" } ?? "Off"
    }

    // MARK: - Single pill button

    @ViewBuilder
    private func quickAccessButton(
        systemImage: String,
        label: String,
        accessibilityId: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(label, systemImage: systemImage)
                .lineLimit(1)
                .font(.caption.weight(.medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.white.opacity(0.18))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(accessibilityId)
    }
}
#endif

// MARK: - Sign-in button (age-restricted / login-required errors)
//
// Isolated into its own view so the @State sheet-presentation flag lives in a
// dedicated scope.  PlayerControlsOverlay cannot hold its own mutable @State in
// the extension methods where this is used, so we delegate to this tiny helper.
private struct SignInButtonView: View {
    @State private var showSignIn = false

    var body: some View {
        Button {
            showSignIn = true
        } label: {
            Text("Sign In")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.black)
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                .background(Color.white)
                .clipShape(Capsule())
        }
        .accessibilityIdentifier("player.signInButton")
        .sheet(isPresented: $showSignIn) { SignInView() }
    }
}
