import SwiftUI
import iPocketTubeCore

// MARK: - BrowseView
//
// Main home feed.  Mirrors the Android `BrowseFragment`.

public struct BrowseView: View {
    @Environment(BrowseViewModel.self) private var vm
    @Environment(AuthService.self) private var auth
    @Environment(SettingsStore.self) private var settings
    @Environment(\.innerTubeAPI) private var api
    @State private var selectedVideo: Video?
    @State private var selectedPlaylist: Video?
    @State private var shortsPresentation: ShortsPresentation?
    @State private var channelDestination: ChannelDestination?
    @State private var showSignIn = false
    @State private var showError = false
    #if os(iOS)
    @Environment(PlayerRouter.self) private var playerRouter
    #endif

    public init() {}

    public var body: some View {
        Group {
            if vm.isLoading && vm.videoGroups.isEmpty {
                ProgressView("Loading…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if vm.videoGroups.isEmpty && !vm.isLoading {
                emptyState
            } else {
                content
            }
        }
        .navigationTitle(vm.currentSection.title)
        .toolbar { sectionPicker }
        #if !os(iOS) && !os(macOS)
        .fullScreenCover(item: $selectedVideo) { video in
            PlayerView(video: video, api: api)
        }
        #endif
        .navigationDestination(item: $selectedPlaylist) { stub in
            PlaylistView(playlistId: stub.id, playlistTitle: stub.title, api: api, catalogContext: .search)
        }
        .navigationDestination(item: $channelDestination) { dest in
            ChannelView(channelId: dest.channelId, catalogContext: .search)
        }
        .onReceive(NotificationCenter.default.publisher(for: .openChannel)) { note in
            guard let channelId = note.userInfo?["channelId"] as? String, !channelId.isEmpty else { return }
            channelDestination = ChannelDestination(channelId: channelId)
        }
        .alert("Error", isPresented: $showError, presenting: vm.error) { _ in
            Button("Retry") { vm.loadContent(refresh: true) }
            Button("Dismiss", role: .cancel) { vm.error = nil }
        } message: { err in
            Text(err.localizedDescription)
        }
        .onChange(of: vm.error == nil ? 0 : 1) { _, hasError in
            if hasError == 1 { showError = true }
        }
        #if !os(macOS)
        .fullScreenCover(item: $shortsPresentation) { target in
            ShortsPlayerView(videos: target.videos, startIndex: target.startIndex, api: api)
        }
        #endif
        .sheet(isPresented: $showSignIn) { SignInView() }
        .onAppear {
            if vm.videoGroups.isEmpty { vm.loadContent() }
        }
        .refreshable { vm.loadContent(refresh: true) }
    }

    // MARK: - Subviews

    private var content: some View {
        let allVideos = FeedCatalogPolicy.visibleVideos(
            vm.videoGroups.flatMap(\.videos),
            showShorts: settings.settings.showShorts
        )

        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if vm.isAuthRequired && !auth.isSignedIn { guestBanner }
                VideoGridSection(
                    videos: allVideos,
                    onSelect: { selectVideo($0, from: allVideos) },
                    loadMore: {
                        if let last = allVideos.last {
                            vm.loadMoreIfNeeded(lastVideo: last)
                        }
                    },
                    catalogContext: .search
                )
                if vm.isLoading {
                    ProgressView().frame(maxWidth: .infinity).padding()
                }
            }
        }
    }

    private func selectVideo(_ video: Video, from groupVideos: [Video]) {
        if vm.currentSection.type == .playlists {
            selectedPlaylist = video
        } else if video.isShort {
            #if os(iOS)
            playerRouter.open(video: video, api: api)
            #else
            let shorts = groupVideos.filter { $0.isShort }
            let idx = shorts.firstIndex(where: { $0.id == video.id }) ?? 0
            shortsPresentation = ShortsPresentation(videos: shorts, startIndex: idx)
            #endif
        } else {
            #if os(iOS)
            playerRouter.open(video: video, api: api)
            #else
            selectedVideo = video
            #endif
        }
    }

    private var guestBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: AppSymbol.personCircle)
                .font(.title2)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Sign in for your personal feed")
                    .font(.subheadline.weight(.semibold))
                Text("Showing popular videos")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Sign In") { showSignIn = true }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        #if !os(tvOS)
        .background(.bar)
        #endif
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: vm.isAuthRequired ? AppSymbol.personCircleWarning : AppSymbol.tvPlay)
                .font(.system(size: 60))
                .foregroundStyle(.secondary)
            if vm.isAuthRequired && !auth.isSignedIn {
                Text("Sign in to see your feed")
                    .font(.title3)
                Text("Your home feed, subscriptions and history\nrequire a Google account.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Sign In") { showSignIn = true }
                    .buttonStyle(.borderedProminent)
            } else {
                Text("Nothing here yet")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Button("Refresh") { vm.loadContent(refresh: true) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ToolbarContentBuilder
    private var sectionPicker: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Picker("Section", selection: Binding(
                get: { vm.currentSection },
                set: { vm.select(section: $0) }
            )) {
                ForEach(vm.sections) { section in
                    Text(LocalizedStringKey(section.title), bundle: .module).tag(section)
                }
            }
            .pickerStyle(.segmented)
            .fixedSize()
        }
    }
}

// MARK: - VideoGridSection

struct VideoGridSection: View {
    let videos: [Video]
    let onSelect: (Video) -> Void
    var loadMore: (() -> Void)? = nil
    var catalogContext: VideoCardCatalogContext = .standard

    @Environment(SettingsStore.self) private var store

    var body: some View {
        #if os(iOS)
        let compact = VideoCardLayoutPolicy.variant(
            for: catalogContext,
            compactSearchCards: store.settings.compactSearchCards,
            compactMediaLibraryCards: store.settings.compactMediaLibraryCards
        ) == .compact
        #else
        let compact = store.settings.compactThumbnails
        #endif
        if compact {
            LazyVStack(spacing: 8) {
                ForEach(videos) { video in
                    #if os(tvOS)
                    VideoCardView(video: video, compact: true, onSelect: { onSelect(video) })
                        .padding(.horizontal)
                        .padding(.vertical, 2)
                        .accessibilityIdentifier("video.card.\(video.id)")
                        .onAppear {
                            if video.id == videos.last?.id { loadMore?() }
                        }
                    #else

                    VideoCardView(video: video, compact: true)
                        .padding(.horizontal)
                        .padding(.vertical, 2)
                        .accessibilityIdentifier("video.card.\(video.id)")
                        .accessibilityValue(video.isShort ? "short" : "")
                        .onTapGesture { onSelect(video) }
                        .onAppear {
                            if video.id == videos.last?.id { loadMore?() }
                        }
                    #endif
                }
            }
            #if os(tvOS)
            .focusSection()
            #endif
        } else {
            #if os(tvOS)
            // LazyVGrid on tvOS causes the first row of grid items to appear
            // invisible — the focus engine cannot traverse cells that have not
            // been laid out yet. Use LazyVStack + HStack rows (4 per row) instead,
            // which is the same approach BrowseView.content already uses on tvOS.
            let columnCount = 4
            LazyVStack(alignment: .leading, spacing: videoGridRowSpacing) {
                ForEach(Array(stride(from: 0, to: videos.count, by: columnCount)), id: \.self) { startIdx in
                    let rowVideos = Array(videos[startIdx..<min(startIdx + columnCount, videos.count)])
                    HStack(alignment: .top, spacing: videoGridRowSpacing) {
                        ForEach(rowVideos) { video in
                            VideoCardView(video: video, compact: false, onSelect: { onSelect(video) })
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
                        if rowVideos.last?.id == videos.last?.id { loadMore?() }
                    }
                }
            }
            .padding(.horizontal, 0)
            .padding(.vertical, 8)
            #if os(tvOS)
            .focusSection()
            #endif
            #else
            let columns = Array(
                repeating: GridItem(.flexible(), spacing: videoGridRowSpacing),
                count: FeedCatalogPolicy.iOSColumnCount
            )
            LazyVGrid(columns: columns, spacing: videoGridRowSpacing) {
                ForEach(videos) { video in
                    VideoCardView(video: video, compact: false)
                        .accessibilityIdentifier("video.card.\(video.id)")
                        .accessibilityValue(video.isShort ? "short" : "")
                        .onTapGesture { onSelect(video) }
                        .onAppear {
                            if video.id == videos.last?.id { loadMore?() }
                        }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            #endif
        }
    }
}

// MARK: - VideoRowSection

/// Horizontal scrolling shelf row — used for home feed shelves (layout == .row).
struct VideoRowSection: View {
    let videos: [Video]
    let onSelect: (Video) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: videoGridRowSpacing) {
                ForEach(videos) { video in
                    #if os(tvOS)
                    VideoCardView(video: video, compact: false, onSelect: { onSelect(video) })
                        .frame(width: 360)
                        .accessibilityIdentifier("video.card.\(video.id)")
                    #else
                    VideoCardView(video: video, compact: false)
                        .frame(width: 220)
                        .accessibilityIdentifier("video.card.\(video.id)")
                        .onTapGesture { onSelect(video) }
                    #endif
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 4)
        }
        #if os(tvOS)
        .focusSection()
        #endif
    }
}
