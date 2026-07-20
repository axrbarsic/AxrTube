import SwiftUI
import iPocketTubeCore

// MARK: - ChannelView
//
// Displays channel info, subscriber count and a grid of recent uploads.
// Mirrors the Android `ChannelFragment`.

// MARK: - ChannelFilter

private enum ChannelFilter: String, CaseIterable {
    case all    = "All"
    case shorts = "Shorts"
}

public struct ChannelView: View {
    public let channelId: String
    public let catalogContext: VideoCardCatalogContext
    @State private var vm = ChannelViewModel()
    @State private var selectedVideo: Video?
    @State private var shortsPresentation: ShortsPresentation?
    @State private var channelDestination: ChannelDestination?
    @State private var filter: ChannelFilter = .all
    @State private var isFollowedLocally = false
    @Environment(SettingsStore.self) private var store
    @Environment(AuthService.self) private var auth
    @Environment(\.innerTubeAPI) private var api
    #if os(iOS)
    @Environment(PlayerRouter.self) private var playerRouter
    #endif

    public init(channelId: String, catalogContext: VideoCardCatalogContext) {
        self.channelId = channelId
        self.catalogContext = catalogContext
    }

    public var body: some View {
        Group {
            if vm.isLoading && vm.channel == nil {
                ProgressView("Loading channel…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("channel.view")
            } else {
                content
            }
        }
        .navigationTitle(vm.channel?.title ?? String(localized: "Channel", bundle: .module))
        .onAppear { vm.load(channelId: channelId) }
        .task(id: vm.channel?.id) {
            guard let id = vm.channel?.id else { return }
            isFollowedLocally = await LocalSubscriptionStore.shared.isFollowing(id)
        }
        #if !os(iOS) && !os(macOS)
        .fullScreenCover(item: $selectedVideo) { video in
            PlayerView(video: video, api: api)
        }
        #endif
        #if os(macOS)
        .navigationDestination(item: $selectedVideo) { video in
            PlayerView(video: video, api: api)
        }
        #endif
        .navigationDestination(item: $channelDestination) { dest in
            ChannelView(channelId: dest.channelId, catalogContext: catalogContext)
        }
        .onReceive(NotificationCenter.default.publisher(for: .openChannel)) { note in
            guard let channelId = note.userInfo?["channelId"] as? String, !channelId.isEmpty else { return }
            channelDestination = ChannelDestination(channelId: channelId)
        }
        #if !os(macOS)
        .fullScreenCover(item: $shortsPresentation) { target in
            ShortsPlayerView(videos: target.videos, startIndex: target.startIndex, api: api)
        }
        #endif
        .toolbar {
            if let channel = vm.channel {
                #if os(macOS)
                ToolbarItem(placement: .automatic) {
                    let isExcluded = store.settings.sponsorBlockExcludedChannels[channel.id] != nil
                    Button {
                        iPocketTubeHaptics.shared.perform(.settingsToggle)
                        toggleSponsorBlockExclusion(for: channel)
                    } label: {
                        Label(
                            isExcluded ? "Remove SponsorBlock Exclusion" : "Exclude from SponsorBlock",
                            systemImage: isExcluded ? "person.crop.circle.badge.checkmark" : "person.crop.circle.badge.minus"
                        )
                    }
                }
                #else
                ToolbarItem(placement: .topBarTrailing) {
                    let isExcluded = store.settings.sponsorBlockExcludedChannels[channel.id] != nil
                    Button {
                        iPocketTubeHaptics.shared.perform(.settingsToggle)
                        toggleSponsorBlockExclusion(for: channel)
                    } label: {
                        Label(
                            isExcluded ? "Remove SponsorBlock Exclusion" : "Exclude from SponsorBlock",
                            systemImage: isExcluded ? "person.crop.circle.badge.checkmark" : "person.crop.circle.badge.minus"
                        )
                    }
                    .accessibilityIdentifier("channel.sponsorBlockButton")
                }
                #endif
            }
        }
    }

    private var content: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                // Channel header
                if let channel = vm.channel {
                    channelHeader(channel)
                }

                // All / Shorts filter. When Shorts are hidden globally, the
                // dedicated route disappears too; a stale selection is reset below.
                if store.settings.showShorts {
                    Picker("Filter", selection: Binding(
                        get: { filter },
                        set: { newValue in
                            guard newValue != filter else { return }
                            iPocketTubeHaptics.shared.perform(.segmentSelection)
                            filter = newValue
                        }
                    )) {
                        ForEach(ChannelFilter.allCases, id: \.self) { tab in
                            Text(LocalizedStringKey(tab.rawValue), bundle: .module).tag(tab)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)
                    .padding(.vertical, 10)
                    .accessibilityIdentifier("channel.filterPicker")
                }

                let filtered = filteredVideos
                if vm.error != nil && vm.channel == nil {
                    channelErrorState
                } else if filtered.isEmpty && !vm.isLoading {
                    channelEmptyState
                } else if filter == .shorts {
                    shortsGrid(filtered)
                } else {
                    videosGrid(filtered)
                }

                if vm.isLoading {
                    ProgressView().frame(maxWidth: .infinity).padding()
                }
            }
        }
        .refreshable { vm.load(channelId: channelId) }
        .onChange(of: store.settings.showShorts) { _, showShorts in
            if !showShorts { filter = .all }
        }
        .accessibilityIdentifier("channel.view")
    }

    // MARK: - Filtered data

    private var filteredVideos: [Video] {
        switch filter {
        case .all:    return vm.videos.filter { !store.settings.hideShorts || !$0.isShort }
        case .shorts: return vm.videos.filter { $0.isShort }
        }
    }

    private var channelErrorState: some View {
        VStack(spacing: 14) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 44))
                .foregroundStyle(iPocketTubeVisualTokens.secondaryText)
            Text("Could not load channel")
                .font(.headline)
            Button("Retry") {
                iPocketTubeHaptics.shared.perform(.downloadRetry)
                vm.load(channelId: channelId)
            }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
        .accessibilityIdentifier("channel.error")
    }

    private var channelEmptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "play.rectangle.on.rectangle")
                .font(.system(size: 44))
                .foregroundStyle(iPocketTubeVisualTokens.secondaryText)
            Text("No videos available in this channel")
                .font(.headline)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
        .accessibilityIdentifier("channel.empty")
    }

    // MARK: - Grid layouts

    private func videosGrid(_ videos: [Video]) -> some View {
        let compact = usesCompactCards
        return Group {
            if compact {
                LazyVStack(spacing: 0) {
                    ForEach(videos) { video in
                        VideoCardView(video: video, compact: true)
                            .padding(.horizontal)
                            .padding(.vertical, 6)
                            .accessibilityIdentifier("video.card.\(video.id)")
                            .onTapGesture {
                                iPocketTubeHaptics.shared.perform(.contentSelection)
                                #if os(iOS)
                                playerRouter.open(video: video, api: api)
                                #else
                                selectedVideo = video
                                #endif
                            }
                            .onAppear {
                                if video.id == vm.videos.last?.id { vm.loadMore() }
                            }
                        Divider().padding(.horizontal)
                    }
                }
            } else {
                #if os(tvOS)
                let columnCount = 4
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(stride(from: 0, to: videos.count, by: columnCount)), id: \.self) { startIdx in
                        let rowVideos = Array(videos[startIdx..<min(startIdx + columnCount, videos.count)])
                        HStack(alignment: .top, spacing: 12) {
                            ForEach(rowVideos) { video in
                                VideoCardView(video: video, compact: false, onSelect: { selectedVideo = video })
                                    .frame(maxWidth: .infinity)
                                    .accessibilityIdentifier("video.card.\(video.id)")
                            }
                            let remainder = columnCount - rowVideos.count
                            if remainder > 0 {
                                ForEach(0..<remainder, id: \.self) { _ in
                                    Color.clear.frame(maxWidth: .infinity)
                                }
                            }
                        }
                        .onAppear {
                            if rowVideos.last?.id == vm.videos.last?.id { vm.loadMore() }
                        }
                    }
                }
                .padding()
                #else
                LazyVGrid(columns: videoGridColumns, spacing: videoGridRowSpacing) {
                    ForEach(videos) { video in
                        VideoCardView(video: video, compact: false)
                            .accessibilityIdentifier("video.card.\(video.id)")
                            .onTapGesture {
                                iPocketTubeHaptics.shared.perform(.contentSelection)
                                #if os(iOS)
                                playerRouter.open(video: video, api: api)
                                #else
                                selectedVideo = video
                                #endif
                            }
                            .onAppear {
                                if video.id == vm.videos.last?.id { vm.loadMore() }
                            }
                    }
                }
                .padding()
                #endif
            }
        }
    }

    private var usesCompactCards: Bool {
        #if os(iOS)
        VideoCardLayoutPolicy.variant(
            for: catalogContext,
            compactCards: store.settings.compactSearchCards
        ) == .compact
        #else
        store.settings.compactThumbnails
        #endif
    }

    private func shortsGrid(_ videos: [Video]) -> some View {
        let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]
        return LazyVGrid(columns: columns, spacing: 8) {
            ForEach(videos) { video in
                VideoCardView(video: video)
                    .aspectRatio(9/16, contentMode: .fit)
                    .onTapGesture {
                        iPocketTubeHaptics.shared.perform(.contentSelection)
                        selectShort(video, from: videos)
                    }
                    .onAppear {
                        if video.id == vm.videos.last?.id { vm.loadMore() }
                    }
            }
        }
        .padding(.horizontal)
        .accessibilityIdentifier("channel.videoGrid")
    }

    private func selectShort(_ video: Video, from videos: [Video]) {
        #if os(iOS)
        playerRouter.open(video: video, api: api)
        #else
        let idx = videos.firstIndex(where: { $0.id == video.id }) ?? 0
        shortsPresentation = ShortsPresentation(videos: videos, startIndex: idx)
        #endif
    }

    private func toggleSponsorBlockExclusion(for channel: Channel) {
        if store.settings.sponsorBlockExcludedChannels[channel.id] != nil {
            store.settings.sponsorBlockExcludedChannels.removeValue(forKey: channel.id)
        } else {
            store.settings.sponsorBlockExcludedChannels[channel.id] = channel.title
        }
    }

    private func channelHeader(_ channel: Channel) -> some View {
        HStack(spacing: 16) {
            AsyncImage(url: channel.thumbnailURL) { img in
                img.resizable().scaledToFill()
            } placeholder: {
                Circle().fill(Color.secondary.opacity(0.3))
            }
            .frame(width: 72, height: 72)
            .clipShape(Circle())

            VStack(alignment: .leading, spacing: 4) {
                Text(channel.title)
                    .font(.title2)
                    .fontWeight(.semibold)
                    .accessibilityIdentifier("channel.title")
                if let subs = channel.subscriberCount {
                    Text(subs)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if let desc = channel.description, !desc.isEmpty {
                    Text(desc)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer()
            if !auth.isSignedIn {
                Button {
                    iPocketTubeHaptics.shared.perform(.primaryAction)
                    Task {
                        await toggleFollow(channel)
                        iPocketTubeHaptics.shared.perform(.operationSucceeded)
                    }
                } label: {
                    Label(
                        isFollowedLocally ? "Unfollow" : "Follow",
                        systemImage: isFollowedLocally ? "bell.slash" : "bell"
                    )
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("channel.followButton")
            }
        }
        .padding()
        .background(.background)
        .accessibilityIdentifier("channel.header")
    }

    private func toggleFollow(_ channel: Channel) async {
        if isFollowedLocally {
            await LocalSubscriptionStore.shared.unfollow(channelId: channel.id)
            isFollowedLocally = false
        } else {
            let local = LocalChannel(
                id: channel.id,
                title: channel.title,
                thumbnailURL: channel.thumbnailURL
            )
            await LocalSubscriptionStore.shared.follow(local)
            isFollowedLocally = true
        }
    }
}
