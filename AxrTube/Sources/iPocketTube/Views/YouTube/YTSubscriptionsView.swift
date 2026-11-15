#if os(iOS)
import SwiftUI
import iPocketTubeCore

/// YouTube "Подписки": a strip of channel avatars with "Все", filter chips,
/// then the newest uploads of subscribed channels. Guests see the channels
/// they follow on this device.
struct YTSubscriptionsView: View {
    enum Filter: String, CaseIterable, Identifiable {
        case all, today, videos, shorts, live
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: "Все"
            case .today: "Сегодня"
            case .videos: "Видео"
            case .shorts: "Shorts"
            case .live: "Трансляции"
            }
        }
    }

    @State private var feed: BrowseViewModel
    @State private var channelsVM: BrowseViewModel
    @State private var filter: Filter = .all
    @State private var showAllChannels = false
    @State private var channel: ChannelDestination?
    @State private var shorts: ShortsLaunch?
    @State private var isAtTop = true
    @Environment(AuthService.self) private var auth
    @Environment(SettingsStore.self) private var store
    @Environment(PlayerRouter.self) private var playerRouter
    @Environment(\.innerTubeAPI) private var api

    private static let topID = "subs.top"

    init(api: InnerTubeAPI) {
        _feed = State(initialValue: BrowseViewModel(api: api, initialSection: BrowseSection(type: .subscriptions)))
        _channelsVM = State(initialValue: BrowseViewModel(api: api, initialSection: BrowseSection(type: .channels)))
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    Color.clear.frame(height: 0).id(Self.topID)
                    channelStrip
                    chips
                    content
                }
            }
            .onScrollGeometryChange(for: Bool.self) { geo in
                geo.contentOffset.y + geo.contentInsets.top < 8
            } action: { _, atTop in isAtTop = atTop }
            .refreshable { reload() }
            .onReceive(NotificationCenter.default.publisher(for: .ytTabReselected)) { note in
                guard (note.object as? String) == YTTab.subscriptions.rawValue else { return }
                if isAtTop { reload() } else { withAnimation { proxy.scrollTo(Self.topID, anchor: .top) } }
            }
        }
        .background(YTColor.background)
        .navigationDestination(isPresented: $showAllChannels) {
            YTChannelsView(api: api).navigationTitle("Все подписки")
                .toolbar(.visible, for: .navigationBar)
        }
        .navigationDestination(item: $channel) { dest in
            ChannelView(channelId: dest.channelId, catalogContext: .mediaLibrary)
        }
        .fullScreenCover(item: $shorts) { launch in
            YTShortsPager(videos: launch.videos, startID: launch.startID, onClose: { shorts = nil })
                .ignoresSafeArea()
        }
        .task(id: auth.authSnapshot) {
            let snapshot = auth.authSnapshot
            await feed.applyAuthSnapshot(snapshot)
            await channelsVM.applyAuthSnapshot(snapshot)
            if feed.videoGroups.isEmpty { feed.loadContent(for: BrowseSection(type: .subscriptions), source: "yt-subs") }
            if channelsVM.subscribedChannels.isEmpty {
                channelsVM.loadContent(for: BrowseSection(type: .channels), source: "yt-subs.channels")
            }
        }
        .accessibilityIdentifier("subscriptions.feed")
    }

    // MARK: Channels strip

    @ViewBuilder private var channelStrip: some View {
        let channels = PinnedChannelStore.shared.orderedChannels(channelsVM.subscribedChannels)
        if !channels.isEmpty {
            HStack(spacing: 0) {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 14) {
                        ForEach(channels) { item in
                            Button { channel = ChannelDestination(channelId: item.id) } label: {
                                VStack(spacing: 6) {
                                    AsyncImage(url: item.thumbnailURL) { phase in
                                        if case .success(let image) = phase {
                                            image.resizable().scaledToFill()
                                        } else {
                                            YTChannelAvatar(title: item.title, size: 56)
                                        }
                                    }
                                    .frame(width: 56, height: 56)
                                    .clipShape(Circle())
                                    Text(item.title)
                                        .font(.system(size: 11))
                                        .foregroundStyle(YTColor.secondaryText)
                                        .lineLimit(1)
                                        .frame(width: 64)
                                }
                            }
                            .buttonStyle(YTPressStyle())
                        }
                    }
                    .padding(.leading, 12)
                }
                Button("Все") { showAllChannels = true }
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color(hex: 0x3EA6FF))
                    .padding(.horizontal, 14)
            }
            .padding(.vertical, 10)
        }
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Filter.allCases) { item in
                    let selected = item == filter
                    Button {
                        iPocketTubeHaptics.shared.perform(.segmentSelection)
                        filter = item
                    } label: {
                        Text(item.title)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(selected ? YTColor.chipSelectedText : YTColor.primaryText)
                            .padding(.horizontal, 12)
                            .frame(height: 32)
                            .background(selected ? YTColor.chipSelected : YTColor.chip,
                                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
    }

    // MARK: Feed

    @ViewBuilder private var content: some View {
        let items = filtered
        if items.isEmpty && feed.isLoading {
            ForEach(0..<3, id: \.self) { _ in YTVideoCardSkeleton() }
        } else if items.isEmpty {
            YTFeedMessage(
                title: auth.isSignedIn ? "Нет новых видео" : "Подпишитесь на каналы, чтобы видеть их новые видео",
                actionTitle: "Обновить"
            ) { reload() }
        } else if filter == .shorts {
            YTShortsShelf(videos: items) { video in shorts = ShortsLaunch(videos: items, startID: video.id) }
        } else {
            ForEach(items) { video in
                YTVideoCard(video: video, onSelect: { playerRouter.open(video: video, api: api) })
                    .onAppear { if video.id == items.last?.id { feed.loadMoreIfNeeded(lastVideo: video) } }
            }
            if feed.isLoading { ProgressView().frame(maxWidth: .infinity).padding() }
        }
    }

    private var filtered: [Video] {
        var seen = Set<String>()
        let all = feed.videoGroups.flatMap(\.videos).filter { seen.insert($0.id).inserted }
        switch filter {
        case .all: return FeedCatalogPolicy.visibleVideos(all, showShorts: store.settings.showShorts)
        case .videos: return all.filter { !$0.isShort && !$0.isLive }
        case .shorts: return all.filter(\.isShort)
        case .live: return all.filter(\.isLive)
        case .today:
            return all.filter { video in
                guard !video.isShort else { return false }
                if let date = video.publishedAt { return Date().timeIntervalSince(date) < 86_400 }
                let label = (video.publishedTimeText ?? "").lowercased()
                return label.contains("час") || label.contains("мин") || label.contains("hour") || label.contains("minute")
            }
        }
    }

    private func reload() {
        feed.loadContent(for: BrowseSection(type: .subscriptions), refresh: true, source: "yt-subs.refresh")
        channelsVM.reload(section: BrowseSection(type: .channels))
    }
}
#endif
