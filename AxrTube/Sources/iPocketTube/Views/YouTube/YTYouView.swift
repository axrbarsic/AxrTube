#if os(iOS)
import SwiftUI
import iPocketTubeCore

/// The YouTube "Вы" tab: account header, History and Playlists shelves, then
/// rows. Settings open from the gear in the top bar.
struct YTYouView: View {
    typealias Destination = MobileProfileDestination

    @Environment(AuthService.self) private var auth
    @Environment(DownloadStore.self) private var downloadStore
    @Environment(PlayerRouter.self) private var playerRouter
    @Environment(\.innerTubeAPI) private var api
    @State private var showSignIn = false
    @State private var queueCount = 0
    @State private var history: BrowseViewModel?
    @State private var playlists: BrowseViewModel?
    @State private var selectedPlaylist: Video?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                accountHeader
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                if auth.isSignedIn {
                    shelf("История", destination: .history, videos: history.map(videos) ?? [], style: .video)
                    shelf("Плейлисты", destination: .playlists, videos: playlists.map(videos) ?? [], style: .playlist)
                }
                ForEach(Destination.accountEntries(signedIn: auth.isSignedIn), id: \.self) { profileRow($0) }
                Divider().overlay(YTColor.divider).padding(.vertical, 6)
                ForEach(Destination.deviceEntries, id: \.self) { profileRow($0) }
            }
        }
        .background(YTColor.background)
        .navigationDestination(for: Destination.self) { destination in
            Group {
                switch destination {
                case .channels: YTChannelsView(api: api).navigationTitle("Все подписки")
                case .history: YTFeedView(type: .history, requiresSignIn: true, api: api).navigationTitle("История")
                case .playlists: YTFeedView(type: .playlists, requiresSignIn: true, api: api).navigationTitle("Плейлисты")
                case .watchLater:
                    PlaylistView(playlistId: "WL", playlistTitle: "Смотреть позже", api: api, catalogContext: .mediaLibrary)
                case .liked:
                    PlaylistView(playlistId: "LL", playlistTitle: "Понравившиеся", api: api, catalogContext: .mediaLibrary)
                case .queue:
                    PlaylistView(playlistId: CurrentQueueStore.playlistID, playlistTitle: "Очередь", api: api, catalogContext: .mediaLibrary)
                case .downloads: YTDownloadsView()
                case .settings: SettingsView()
                }
            }
            .toolbar(.visible, for: .navigationBar)
            .navigationBarTitleDisplayMode(.inline)
        }
        .navigationDestination(item: $selectedPlaylist) { stub in
            PlaylistView(playlistId: stub.id, playlistTitle: stub.title, api: api, catalogContext: .mediaLibrary)
                .toolbar(.visible, for: .navigationBar)
        }
        .sheet(isPresented: $showSignIn) { SignInView() }
        .task {
            let count = await CurrentQueueStore.shared.videos.count
            guard !Task.isCancelled else { return }
            queueCount = count
        }
        .task(id: auth.authSnapshot) { await loadShelves() }
    }

    // MARK: Header

    @ViewBuilder private var accountHeader: some View {
        if auth.isSignedIn {
            HStack(spacing: 14) {
                CachedRemoteImage(url: auth.accountAvatarURL) { image in
                    Image(uiImage: image).resizable().scaledToFill()
                } placeholder: {
                        YTChannelAvatar(title: auth.accountName ?? "?", size: 72)
                }
                .frame(width: 72, height: 72)
                .clipShape(Circle())
                Text(auth.accountName ?? "Аккаунт")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(YTColor.primaryText)
            }
        } else {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 14) {
                    Image(systemName: "person.crop.circle.fill")
                        .font(.system(size: 64))
                        .foregroundStyle(YTColor.secondaryText)
                    Text("Вы не вошли в аккаунт")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(YTColor.primaryText)
                }
                Text("Войдите, чтобы видеть историю, плейлисты и рекомендации")
                    .font(.system(size: 14))
                    .foregroundStyle(YTColor.secondaryText)
                Button { showSignIn = true } label: {
                    Label("Войти", systemImage: "person.crop.circle")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color(hex: 0x3EA6FF))
                        .padding(.horizontal, 14)
                        .frame(height: 36)
                        .overlay(Capsule().stroke(YTColor.divider))
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: Shelves

    private enum ShelfStyle { case video, playlist }

    @ViewBuilder
    private func shelf(_ title: String, destination: Destination, videos: [Video], style: ShelfStyle) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title).font(.system(size: 20, weight: .bold))
                Spacer()
                NavigationLink(value: destination) {
                    Text("Все")
                        .font(.system(size: 14, weight: .medium))
                        .padding(.horizontal, 12)
                        .frame(height: 30)
                        .overlay(Capsule().stroke(YTColor.divider))
                }
                .buttonStyle(.plain)
            }
            .foregroundStyle(YTColor.primaryText)
            .padding(.horizontal, 16)
            if videos.isEmpty {
                Text("Пока пусто")
                    .font(.system(size: 13))
                    .foregroundStyle(YTColor.secondaryText)
                    .padding(.horizontal, 16)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 10) {
                        ForEach(videos.prefix(20)) { video in
                            Button {
                                if style == .playlist { selectedPlaylist = video } else { playerRouter.open(video: video, api: api) }
                            } label: { shelfTile(video) }
                            .buttonStyle(YTPressStyle())
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
        }
        .padding(.bottom, 18)
    }

    private func shelfTile(_ video: Video) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ThumbnailFillView(primaryURL: video.thumbnailURL, fallbackURLs: video.thumbnailFallbackURLs)
                .frame(width: 160, height: 90)
                .background(YTColor.placeholder)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            Text(video.title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(YTColor.primaryText)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Text(video.channelTitle)
                .font(.system(size: 12))
                .foregroundStyle(YTColor.secondaryText)
                .lineLimit(1)
        }
        .frame(width: 160, alignment: .leading)
    }

    private func videos(_ vm: BrowseViewModel) -> [Video] {
        vm.videoGroups.flatMap(\.videos)
    }

    private func loadShelves() async {
        guard auth.isSignedIn else {
            history = nil
            playlists = nil
            return
        }
        let snapshot = auth.authSnapshot
        let historyVM = history ?? BrowseViewModel(api: api, initialSection: BrowseSection(type: .history))
        let playlistsVM = playlists ?? BrowseViewModel(api: api, initialSection: BrowseSection(type: .playlists))
        history = historyVM
        playlists = playlistsVM
        await historyVM.applyAuthSnapshot(snapshot)
        await playlistsVM.applyAuthSnapshot(snapshot)
        if historyVM.videoGroups.isEmpty { historyVM.loadContent(for: BrowseSection(type: .history), source: "you.history") }
        if playlistsVM.videoGroups.isEmpty { playlistsVM.loadContent(for: BrowseSection(type: .playlists), source: "you.playlists") }
    }

    // MARK: Rows

    private var downloadsDetail: String? {
        let count = downloadStore.entries.filter { $0.status == .completed }.count
            + PinnedStreamLibrary.shared.entries.count
        return count > 0 ? "\(count)" : nil
    }

    @ViewBuilder private func profileRow(_ destination: Destination) -> some View {
        switch destination {
        case .channels: row(destination, "Все подписки", "person.2")
        case .playlists: row(destination, "Плейлисты", "list.bullet.rectangle")
        case .history: row(destination, "История", "clock.arrow.circlepath")
        case .watchLater: row(destination, "Смотреть позже", "clock")
        case .liked: row(destination, "Понравившиеся", "hand.thumbsup")
        case .queue: row(destination, "Очередь", "text.line.first.and.arrowtriangle.forward", detail: queueCount > 0 ? String(queueCount) : nil)
        case .downloads: row(destination, "Скачанные", "arrow.down.to.line", detail: downloadsDetail)
        case .settings: row(destination, "Настройки", "gearshape")
        }
    }

    private func row(_ destination: Destination, _ title: String, _ icon: String, detail: String? = nil) -> some View {
        NavigationLink(value: destination) {
            HStack(spacing: 22) {
                Image(systemName: icon)
                    .font(.system(size: 20))
                    .frame(width: 26)
                Text(title).font(.system(size: 16))
                Spacer()
                if let detail {
                    Text(detail).font(.system(size: 14)).foregroundStyle(YTColor.secondaryText)
                }
            }
            .foregroundStyle(YTColor.primaryText)
            .padding(.horizontal, 16)
            .frame(height: 50)
            .contentShape(Rectangle())
        }
        .buttonStyle(YTPressStyle())
        .accessibilityIdentifier("you.\(destination)")
    }
}
#endif
