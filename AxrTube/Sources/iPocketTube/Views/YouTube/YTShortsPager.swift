#if os(iOS)
import SwiftUI
import iPocketTubeCore

/// YouTube Shorts: a full-height vertical pager. Exactly one page is active;
/// it owns the shared ad-free AVPlayer layer, the others show their poster.
struct YTShortsPager: View {
    let videos: [Video]
    var startID: String? = nil
    var onNearEnd: () -> Void = {}
    var onClose: (() -> Void)? = nil

    @Environment(PlayerStateStore.self) private var playerState
    @Environment(PlayerRouter.self) private var playerRouter
    @Environment(\.scenePhase) private var scenePhase
    @State private var activeID: String?
    @State private var commentsFor: Video?

    var body: some View {
        GeometryReader { geo in
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(videos) { video in
                        YTShortPage(
                            video: video,
                            isActive: video.id == activeID,
                            showComments: { commentsFor = video }
                        )
                        .frame(width: geo.size.width, height: geo.size.height)
                        .id(video.id)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $activeID)
            .scrollIndicators(.hidden)
        }
        .background(Color.black)
        .overlay(alignment: .topLeading) {
            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .shadow(radius: 3)
                }
                .padding(.leading, 6)
                .accessibilityLabel("Назад")
            }
        }
        .onAppear {
            if activeID == nil { activeID = startID ?? videos.first?.id }
            playActive()
        }
        .onChange(of: activeID) { _, _ in playActive() }
        .onChange(of: videos.first?.id) { _, _ in
            if activeID == nil || !videos.contains(where: { $0.id == activeID }) {
                activeID = videos.first?.id
            }
        }
        .onDisappear {
            // Leaving Shorts ends inline playback, like switching tabs in YouTube.
            if playerState.presentation == .inline { playerState.stop() }
        }
        .sheet(item: $commentsFor) { video in
            YTCommentsSheet(videoID: video.id)
                .presentationDetents([.medium, .large])
        }
        .accessibilityIdentifier("shorts.pager")
    }

    private func playActive() {
        guard let id = activeID, let video = videos.first(where: { $0.id == id }) else { return }
        playerRouter.playInline(video: video)
        if let index = videos.firstIndex(where: { $0.id == id }), index >= videos.count - 3 {
            onNearEnd()
        }
    }
}

/// One Short: poster or live video, tap to pause, actions on the right.
private struct YTShortPage: View {
    let video: Video
    let isActive: Bool
    let showComments: () -> Void

    @Environment(PlayerStateStore.self) private var playerState
    @Environment(AuthService.self) private var auth

    private var vm: PlaybackViewModel { playerState.vm }

    var body: some View {
        ZStack {
            ThumbnailFillView(primaryURL: video.thumbnailURL, fallbackURLs: video.thumbnailFallbackURLs)
                .clipped()
            if isActive {
                FullScreenPlayerLayerView(hostView: playerState.playerHostView, videoGravity: .resizeAspect)
                    .opacity(vm.isLoading ? 0 : 1)
                    .accessibilityHidden(true)
                if vm.isLoading { ProgressView().tint(.white).scaleEffect(1.3) }
                if !vm.isPlaying, !vm.isLoading {
                    Image(systemName: "play.fill")
                        .font(.system(size: 54))
                        .foregroundStyle(.white.opacity(0.85))
                        .allowsHitTesting(false)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard isActive else { return }
            iPocketTubeHaptics.shared.perform(.playbackTransport)
            vm.togglePlayPause()
        }
        .overlay(alignment: .bottom) { bottomInfo }
        .overlay(alignment: .bottomTrailing) { actions }
        .overlay(alignment: .bottom) { progress }
        .clipped()
    }

    private var bottomInfo: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                guard let id = video.channelId, !id.isEmpty else { return }
                NotificationCenter.default.post(name: .openChannel, object: nil, userInfo: ["channelId": id])
            } label: {
                HStack(spacing: 8) {
                    YTChannelAvatar(title: video.channelTitle, size: 32)
                    Text(video.channelTitle).font(.system(size: 14, weight: .semibold))
                }
            }
            .buttonStyle(.plain)
            Text(video.title)
                .font(.system(size: 14))
                .lineLimit(2)
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.6), radius: 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 12)
        .padding(.trailing, 76)
        .padding(.bottom, 20)
    }

    private var actions: some View {
        VStack(spacing: 22) {
            if auth.isSignedIn {
                action(isActive && vm.likeStatus == .like ? "hand.thumbsup.fill" : "hand.thumbsup", "Нравится") { vm.like() }
                action(isActive && vm.likeStatus == .dislike ? "hand.thumbsdown.fill" : "hand.thumbsdown", "Не нравится") { vm.dislike() }
            }
            action("text.bubble", "Комментарии", enabled: true, perform: showComments)
            if let url = URL(string: "https://www.youtube.com/shorts/\(video.id)") {
                ShareLink(item: url) { actionLabel("arrowshape.turn.up.right", "Поделиться") }
                    .buttonStyle(.plain)
            }
        }
        .padding(.trailing, 10)
        .padding(.bottom, 26)
    }

    private func action(_ icon: String, _ title: String, enabled: Bool? = nil, perform: @escaping () -> Void) -> some View {
        Button {
            iPocketTubeHaptics.shared.perform(.primaryAction)
            perform()
        } label: { actionLabel(icon, title) }
        .buttonStyle(.plain)
        .disabled(!(enabled ?? isActive))
    }

    private func actionLabel(_ icon: String, _ title: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 26))
            Text(title).font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.6), radius: 3)
        .frame(minWidth: 56)
    }

    @ViewBuilder private var progress: some View {
        if isActive, vm.duration > 0 {
            GeometryReader { geo in
                Rectangle().fill(YTColor.brandRed)
                    .frame(width: geo.size.width * min(max(vm.currentTime / vm.duration, 0), 1))
            }
            .frame(height: 2)
        }
    }
}
#endif
