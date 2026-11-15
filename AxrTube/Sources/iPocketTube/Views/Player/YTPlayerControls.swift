#if os(iOS)
import SwiftUI
import iPocketTubeCore

/// YouTube iOS player chrome: minimize, autoplay, cast, captions and settings
/// on top; previous / play-pause / next in the centre; time, scrubber and
/// full-screen at the bottom.
struct YTPlayerControls: View {
    let isLandscape: Bool
    let safeAreaInsets: EdgeInsets
    let isFullScreen: Bool
    let onToggleFullScreen: () -> Void
    let onMinimize: () -> Void
    let onSettings: () -> Void
    let onCaptions: () -> Void

    @Environment(PlayerStateStore.self) private var playerState
    @Environment(SettingsStore.self) private var store
    private var vm: PlaybackViewModel { playerState.vm }

    var body: some View {
        ZStack {
            Color.black.opacity(0.45)
                .contentShape(Rectangle())
                .onTapGesture { vm.toggleControls() }
            VStack(spacing: 0) {
                topBar
                Spacer(minLength: 0)
                centre
                Spacer(minLength: 0)
                bottomBar
            }
            .padding(.top, isLandscape ? max(safeAreaInsets.top, 12) : 4)
            .padding(.bottom, isLandscape ? max(safeAreaInsets.bottom, 10) : 0)
            .padding(.horizontal, isLandscape ? max(max(safeAreaInsets.leading, safeAreaInsets.trailing), 12) : 4)
        }
        .foregroundStyle(.white)
    }

    // MARK: Top

    private var topBar: some View {
        HStack(spacing: 2) {
            iconButton("chevron.down", label: "Свернуть", size: 22, action: onMinimize)
                .accessibilityIdentifier("player.backButton")
            if isLandscape {
                Text(vm.playerInfo?.video.title ?? playerState.currentVideo?.title ?? "")
                    .font(.system(size: 16, weight: .semibold))
                    .lineLimit(1)
                    .accessibilityIdentifier("player.titleLabel")
            }
            Spacer()
            autoplayToggle
            AirPlayRoutePickerView()
                .frame(width: 40, height: 40)
                .accessibilityIdentifier("player.airPlayButton")
            iconButton(vm.selectedCaption == nil ? "captions.bubble" : "captions.bubble.fill", label: "Субтитры", size: 19, action: onCaptions)
                .disabled(vm.availableCaptions.isEmpty)
                .opacity(vm.availableCaptions.isEmpty ? 0.4 : 1)
            iconButton("gearshape", label: "Настройки", size: 20, action: onSettings)
                .accessibilityIdentifier("player.moreButton")
        }
    }

    private var autoplayToggle: some View {
        @Bindable var store = store
        return Button {
            iPocketTubeHaptics.shared.perform(.settingsToggle)
            store.settings.autoplayEnabled.toggle()
            vm.toastMessage = store.settings.autoplayEnabled ? "Автовоспроизведение включено" : "Автовоспроизведение выключено"
        } label: {
            ZStack(alignment: store.settings.autoplayEnabled ? .trailing : .leading) {
                Capsule().fill(.white.opacity(0.35)).frame(width: 34, height: 14)
                Circle()
                    .fill(store.settings.autoplayEnabled ? .white : Color(white: 0.75))
                    .frame(width: 20, height: 20)
                    .overlay {
                        Image(systemName: store.settings.autoplayEnabled ? "play.fill" : "pause.fill")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.black)
                    }
            }
            .frame(width: 44, height: 40)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(store.settings.autoplayEnabled ? "Автовоспроизведение включено" : "Автовоспроизведение выключено")
    }

    // MARK: Centre

    private var centre: some View {
        HStack(spacing: isLandscape ? 64 : 44) {
            iconButton("backward.end.fill", label: "Предыдущее видео", size: 24) { vm.playPrevious() }
                .disabled(!vm.hasPrevious || vm.isLoading)
                .opacity(vm.hasPrevious && !vm.isLoading ? 1 : 0.35)
                .accessibilityIdentifier("player.prevBtn")
            Button {
                iPocketTubeHaptics.shared.perform(.playbackTransport)
                if vm.videoEnded { vm.seek(to: 0) }
                vm.togglePlayPause()
            } label: {
                Image(systemName: vm.videoEnded ? "arrow.counterclockwise" : (vm.isPlaying ? "pause.fill" : "play.fill"))
                    .font(.system(size: 34))
                    .frame(width: 64, height: 64)
                    .background(.black.opacity(0.35), in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(vm.isLoading)
            .opacity(vm.isLoading ? 0 : 1)
            .accessibilityLabel(vm.isPlaying ? "Пауза" : "Воспроизвести")
            .accessibilityIdentifier("player.playPauseButton")
            iconButton("forward.end.fill", label: "Следующее видео", size: 24) { vm.playNext() }
                .disabled(!vm.hasNext)
                .opacity(vm.hasNext ? 1 : 0.35)
                .accessibilityIdentifier("player.nextBtn")
        }
    }

    // MARK: Bottom

    private var bottomBar: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center) {
                (Text(formatDuration(vm.isScrubbing ? vm.scrubTime : vm.currentTime))
                    + Text(" / ").foregroundColor(.white.opacity(0.7))
                    + Text(formatDuration(vm.duration)).foregroundColor(.white.opacity(0.7)))
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .accessibilityIdentifier("player.currentTimeLabel")
                if let chapter = vm.currentChapter {
                    Text("• \(chapter.title)")
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                }
                Spacer()
                iconButton(isFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                           label: isFullScreen ? "Выйти из полноэкранного режима" : "Во весь экран", size: 17,
                           action: onToggleFullScreen)
                .accessibilityIdentifier("player.landscapeLockButton")
            }
            .padding(.leading, 10)
            YTScrubber(vm: vm)
                .frame(height: 22)
                .padding(.horizontal, isLandscape ? 6 : 0)
        }
    }

    private func iconButton(_ symbol: String, label: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button {
            iPocketTubeHaptics.shared.perform(.primaryAction)
            action()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: size))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// Red YouTube scrubber with SponsorBlock segments and chapter gaps.
struct YTScrubber: View {
    let vm: PlaybackViewModel

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let duration = max(vm.duration, 1)
            let time = vm.isScrubbing ? vm.scrubTime : vm.currentTime
            let fraction = CGFloat(min(max(time / duration, 0), 1))
            ZStack(alignment: .leading) {
                Rectangle().fill(.white.opacity(0.3)).frame(height: vm.isScrubbing ? 5 : 3)
                ForEach(vm.sponsorSegments) { segment in
                    Rectangle()
                        .fill(segment.category.color)
                        .frame(width: max(width * CGFloat((segment.end - segment.start) / duration), 2), height: 3)
                        .offset(x: width * CGFloat(segment.start / duration))
                }
                Rectangle().fill(YTColor.brandRed).frame(width: width * fraction, height: vm.isScrubbing ? 5 : 3)
                ForEach(vm.chapters.dropFirst()) { chapter in
                    Rectangle().fill(.black).frame(width: 2, height: 5)
                        .offset(x: width * CGFloat(chapter.startTime / duration) - 1)
                }
                Circle().fill(YTColor.brandRed)
                    .frame(width: vm.isScrubbing ? 18 : 12, height: vm.isScrubbing ? 18 : 12)
                    .offset(x: width * fraction - (vm.isScrubbing ? 9 : 6))
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .highPriorityGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !vm.isScrubbing { vm.beginScrubbing() }
                        vm.updateScrub(to: Double(min(max(value.location.x / width, 0), 1)) * vm.duration)
                    }
                    .onEnded { _ in
                        iPocketTubeHaptics.shared.perform(.seekCommit)
                        vm.commitScrub()
                    }
            )
        }
        .accessibilityIdentifier("player.progressBar")
        .accessibilityLabel("Перемотка")
    }
}

/// Thin red line along the bottom of the portrait player while controls are hidden.
struct YTThinProgress: View {
    let vm: PlaybackViewModel

    var body: some View {
        GeometryReader { geo in
            Rectangle().fill(YTColor.brandRed)
                .frame(width: geo.size.width * CGFloat(min(max(vm.currentTime / max(vm.duration, 1), 0), 1)), height: 2)
                .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .allowsHitTesting(false)
    }
}
#endif
