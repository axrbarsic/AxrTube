#if os(iOS)
import SwiftUI
import iPocketTubeCore

/// YouTube iOS Home: topic chips, then the feed in service order with a
/// Shorts shelf. Pull-to-refresh and re-tapping the Home tab replace the
/// whole feed with a fresh response and return to the top.
struct YTHomeFeedView: View {
    @State private var model: YouTubeHomeFeedModel
    @State private var selectedPlaylist: Video?
    @State private var shorts: ShortsLaunch?
    @State private var isAtTop = true
    @Environment(AuthService.self) private var auth
    @Environment(SettingsStore.self) private var store
    @Environment(PlayerRouter.self) private var playerRouter
    @Environment(\.innerTubeAPI) private var api
    @Environment(\.scenePhase) private var scenePhase

    private static let topID = "home.top"

    init(api: InnerTubeAPI) {
        _model = State(initialValue: YouTubeHomeFeedModel(api: api))
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: []) {
                    Color.clear.frame(height: 0).id(Self.topID)
                    chips
                    feed
                }
            }
            .onScrollGeometryChange(for: Bool.self) { geo in
                geo.contentOffset.y + geo.contentInsets.top < 8
            } action: { _, atTop in
                isAtTop = atTop
            }
            .refreshable { await model.refresh() }
            .onChange(of: model.replacementID) { _, _ in
                proxy.scrollTo(Self.topID, anchor: .top)
            }
            .onReceive(NotificationCenter.default.publisher(for: .ytTabReselected)) { note in
                guard (note.object as? String) == YTTab.home.rawValue else { return }
                if isAtTop {
                    model.load()
                } else {
                    withAnimation { proxy.scrollTo(Self.topID, anchor: .top) }
                }
            }
        }
        .background(YTColor.background)
        .navigationDestination(item: $selectedPlaylist) { stub in
            PlaylistView(playlistId: stub.id, playlistTitle: stub.title, api: api, catalogContext: .mediaLibrary)
        }
        .fullScreenCover(item: $shorts) { launch in
            YTShortsPager(videos: launch.videos, startID: launch.startID, onClose: { shorts = nil })
                .ignoresSafeArea()
        }
        .task(id: auth.authSnapshot) {
            model.setAdmission(admission)
            await model.applyAuthSnapshot(auth.authSnapshot)
        }
        .onChange(of: store.settings.russianOnlySearchEnabled) { _, _ in
            model.setAdmission(admission)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.refreshIfStale() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .hideVideoFromFeed)) { note in
            if let id = note.userInfo?["videoId"] as? String { model.remove(videoID: id) }
        }
        .accessibilityIdentifier("home.feed")
    }

    // MARK: Chips

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(YouTubeHomeChip.allCases) { chip in
                    let selected = chip == model.chip
                    Button {
                        iPocketTubeHaptics.shared.perform(.segmentSelection)
                        model.select(chip)
                    } label: {
                        Text(chip.title)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(selected ? YTColor.chipSelectedText : YTColor.primaryText)
                            .padding(.horizontal, 12)
                            .frame(height: 32)
                            .background(selected ? YTColor.chipSelected : YTColor.chip,
                                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("home.chip.\(chip.rawValue)")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    // MARK: Feed

    @ViewBuilder
    private var feed: some View {
        let items = regularVideos
        if items.isEmpty && model.isLoading {
            ForEach(0..<3, id: \.self) { _ in YTVideoCardSkeleton() }
        } else if items.isEmpty, let error = model.errorMessage {
            YTFeedMessage(title: error, actionTitle: "Повторить") { model.load() }
        } else if items.isEmpty {
            YTFeedMessage(
                title: store.settings.russianOnlySearchEnabled ? "Нет роликов на русском" : "Здесь пока ничего нет",
                actionTitle: "Обновить"
            ) { model.load() }
        } else {
            if let error = model.errorMessage {
                Text(error)
                    .font(.system(size: 13))
                    .foregroundStyle(YTColor.secondaryText)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            let shelfAfter = min(2, items.count)
            ForEach(Array(items.prefix(shelfAfter))) { card($0) }
            if !shortsShelf.isEmpty {
                YTShortsShelf(videos: shortsShelf) { video in
                    shorts = ShortsLaunch(videos: shortsShelf, startID: video.id)
                }
            }
            ForEach(Array(items.dropFirst(shelfAfter))) { card($0) }
            if model.isLoadingMore {
                ProgressView().frame(maxWidth: .infinity).padding()
            }
            // Keeps paging when a short (filtered) feed ends above the fold.
            Color.clear.frame(height: 1)
                .id(model.videos.count)
                .onAppear { model.loadMore() }
        }
    }

    private func card(_ video: Video) -> some View {
        YTVideoCard(video: video, onSelect: { open(video) })
            .onAppear {
                if video.id == regularVideos.dropLast(4).last?.id || video.id == regularVideos.last?.id {
                    model.loadMore()
                }
            }
    }

    // MARK: Filtering

    /// The Russian-only policy is applied inside the model before a page is
    /// shown, so the feed never rebuilds while languages are being checked.
    private var admission: FeedAdmission {
        store.settings.russianOnlySearchEnabled ? .russianOnly(api: api) : .all
    }

    private var regularVideos: [Video] {
        FeedCatalogPolicy.visibleVideos(model.regularVideos, showShorts: store.settings.showShorts)
    }

    private var shortsShelf: [Video] {
        guard store.settings.showShorts else { return [] }
        return model.shorts
    }

    private func open(_ video: Video) {
        if video.playlistId == video.id {
            selectedPlaylist = video
        } else {
            playerRouter.open(video: video, api: api)
        }
    }
}

/// Videos handed to the Shorts pager from a shelf.
struct ShortsLaunch: Identifiable {
    let videos: [Video]
    let startID: String
    var id: String { startID }
}

/// Centered message with one action, used for empty and error feeds.
struct YTFeedMessage: View {
    let title: String
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Text(title)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(YTColor.primaryText)
                .multilineTextAlignment(.center)
            Button(action: action) {
                Text(actionTitle)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(YTColor.primaryText)
                    .padding(.horizontal, 16)
                    .frame(height: 36)
                    .background(YTColor.chip, in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.vertical, 64)
    }
}

/// Grey placeholder card shown while the first page loads.
struct YTVideoCardSkeleton: View {
    @State private var dim = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Rectangle().fill(YTColor.placeholder).aspectRatio(16 / 9, contentMode: .fit)
            HStack(alignment: .top, spacing: 12) {
                Circle().fill(YTColor.placeholder).frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 6) {
                    RoundedRectangle(cornerRadius: 4).fill(YTColor.placeholder).frame(height: 14)
                    RoundedRectangle(cornerRadius: 4).fill(YTColor.placeholder).frame(width: 180, height: 12)
                }
            }
            .padding(.horizontal, 12)
        }
        .padding(.bottom, 18)
        // Gentle breathing while loading, like YouTube's placeholders.
        .opacity(dim ? 0.55 : 1)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { dim = true }
        }
        .accessibilityHidden(true)
    }
}
#endif
