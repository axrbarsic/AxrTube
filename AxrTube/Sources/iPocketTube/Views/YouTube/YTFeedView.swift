#if os(iOS)
import SwiftUI
import iPocketTubeCore

/// One InnerTube browse feed (subscriptions, history, playlists, Shorts)
/// rendered with YouTube cards. Each instance owns its view model so tabs
/// keep independent scroll positions and loading state.
struct YTFeedView: View {
    let type: BrowseSection.SectionType
    let requiresSignIn: Bool

    @State private var vm: BrowseViewModel
    @State private var selectedPlaylist: Video?
    @State private var showSignIn = false
    @Environment(AuthService.self) private var auth
    @Environment(SettingsStore.self) private var store
    @Environment(PlayerRouter.self) private var playerRouter
    @Environment(\.innerTubeAPI) private var api

    init(type: BrowseSection.SectionType, requiresSignIn: Bool, api: InnerTubeAPI) {
        self.type = type
        self.requiresSignIn = requiresSignIn
        _vm = State(initialValue: BrowseViewModel(api: api, initialSection: BrowseSection(type: type)))
    }

    var body: some View {
        Group {
            if requiresSignIn && !auth.isSignedIn {
                YTSignInPrompt(showSignIn: $showSignIn)
            } else if vm.isLoading && videos.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if videos.isEmpty {
                Text("Здесь пока ничего нет")
                    .foregroundStyle(YTColor.secondaryText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VideoGridSection(
                        videos: videos,
                        onSelect: select,
                        loadMore: { if let last = videos.last { vm.loadMoreIfNeeded(lastVideo: last) } },
                        catalogContext: .mediaLibrary
                    )
                    if vm.isLoading { ProgressView().padding() }
                }
                .refreshable { vm.loadContent(for: BrowseSection(type: type), refresh: true, source: "yt-feed") }
            }
        }
        .background(YTColor.background)
        .navigationDestination(item: $selectedPlaylist) { stub in
            PlaylistView(playlistId: stub.id, playlistTitle: stub.title, api: api, catalogContext: .mediaLibrary)
        }
        .sheet(isPresented: $showSignIn) { SignInView() }
        .task(id: auth.authSnapshot) {
            await vm.applyAuthSnapshot(auth.authSnapshot)
            vm.loadContent(for: BrowseSection(type: type), source: "yt-feed")
        }
    }

    private var videos: [Video] {
        let all = vm.videoGroups.flatMap(\.videos)
        return type == .shorts ? all : FeedCatalogPolicy.visibleVideos(all, showShorts: store.settings.showShorts)
    }

    private func select(_ video: Video) {
        if video.playlistId == video.id {
            selectedPlaylist = video
        } else {
            playerRouter.open(video: video, api: api)
        }
    }
}

/// YouTube's signed-out placeholder for account-bound tabs.
struct YTSignInPrompt: View {
    @Binding var showSignIn: Bool

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "person.crop.circle")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(YTColor.secondaryText)
            Text("Войдите в аккаунт")
                .font(.headline)
                .foregroundStyle(YTColor.primaryText)
            Text("Здесь появятся ваши подписки, история и плейлисты.")
                .font(.subheadline)
                .foregroundStyle(YTColor.secondaryText)
                .multilineTextAlignment(.center)
            Button("Войти") { showSignIn = true }
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 18)
                .padding(.vertical, 9)
                .foregroundStyle(Color(hex: 0x3EA6FF))
                .overlay(Capsule().stroke(YTColor.divider))
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
#endif
