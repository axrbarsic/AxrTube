import SwiftUI
import SmartTubeIOSCore

// MARK: - PlaylistView
//
// Shows the videos inside a user playlist.
// Mirrors the Android `PlaylistFragment`.

public struct PlaylistView: View {
    public let playlistId: String
    public let playlistTitle: String
    public let catalogContext: VideoCardCatalogContext

    @Environment(AuthService.self) private var auth
    @Environment(SettingsStore.self) private var store
    @Environment(\.innerTubeAPI) private var api
    @Environment(\.dismiss) private var dismiss
    @State private var vm: PlaylistViewModel
    @State private var selectedVideo: Video?
    @State private var channelDestination: ChannelDestination?
    #if os(iOS)
    @Environment(PlayerRouter.self) private var playerRouter
    #endif

    public init(
        playlistId: String,
        playlistTitle: String,
        api: InnerTubeAPI,
        catalogContext: VideoCardCatalogContext
    ) {
        self.playlistId = playlistId
        self.playlistTitle = playlistTitle
        self.catalogContext = catalogContext
        _vm = State(initialValue: PlaylistViewModel(api: api))
    }

    public var body: some View {
        Group {
            if vm.isLoading && vm.videos.isEmpty {
                ProgressView("Loading…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if vm.videos.isEmpty {
                emptyState
            } else {
                content
            }
        }
        .navigationTitle(playlistTitle)
        .toolbar {
            if playlistId == CurrentQueueStore.playlistID {
                #if os(iOS) || os(tvOS)
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .destructive) {
                        Task {
                            await CurrentQueueStore.shared.clear()
                            dismiss()
                        }
                    } label: {
                        Label("Clear Queue", systemImage: "trash")
                    }
                }
                #else
                ToolbarItem {
                    Button(role: .destructive) {
                        Task {
                            await CurrentQueueStore.shared.clear()
                            dismiss()
                        }
                    } label: {
                        Label("Clear Queue", systemImage: "trash")
                    }
                }
                #endif
            }
        }
        .onAppear {
            vm.load(playlistId: playlistId)
        }
        #if os(tvOS)
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
        .alert("Error", isPresented: .constant(vm.error != nil), presenting: vm.error) { _ in
            Button("Retry") { vm.load(playlistId: playlistId) }
            Button("Dismiss", role: .cancel) { vm.error = nil }
        } message: { err in
            Text(err.localizedDescription)
        }
    }

    private var content: some View {
        ScrollView {
            if usesCompactCards {

                LazyVStack(spacing: 0) {
                    ForEach(displayVideos) { video in
                        #if os(tvOS)
                        VideoCardView(video: video, compact: true, currentPlaylistId: playlistId, onSelect: {
                                Task { @MainActor in
                                    let captured = displayVideos
                                    await CurrentQueueStore.shared.replaceAll(with: captured)
                                    let startIdx = video.playlistIndex ?? captured.firstIndex(where: { $0.id == video.id }) ?? 0
                                    selectedVideo = await CurrentQueueStore.shared.videoAt(index: startIdx) ?? video
                                }
                            })
                            .padding(.horizontal)
                            .padding(.vertical, 6)
                            .accessibilityIdentifier("video.card.\(video.id)")
                            .onAppear { vm.loadMoreIfNeeded(lastVideo: video) }
                        #else
                        VideoCardView(video: video, compact: true, currentPlaylistId: playlistId)
                            .padding(.horizontal)
                            .padding(.vertical, 6)
                            .accessibilityIdentifier("video.card.\(video.id)")
                            .onTapGesture {
                                #if os(iOS)
                                Task { @MainActor in
                                    let captured = displayVideos
                                    await CurrentQueueStore.shared.replaceAll(with: captured)
                                    let startIdx = video.playlistIndex ?? captured.firstIndex(where: { $0.id == video.id }) ?? 0
                                    let toPlay = await CurrentQueueStore.shared.videoAt(index: startIdx) ?? video
                                    playerRouter.open(video: toPlay, api: api)
                                }
                                #else
                                selectedVideo = video
                                #endif
                            }
                            .onAppear { vm.loadMoreIfNeeded(lastVideo: video) }
                        #endif
                        Divider().padding(.horizontal)
                    }
                    if vm.isLoading {
                        ProgressView().frame(maxWidth: .infinity).padding()
                    }
                }
            } else {
                #if os(tvOS)
                let columnCount = 4
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(stride(from: 0, to: displayVideos.count, by: columnCount)), id: \.self) { startIdx in
                        let rowVideos = Array(displayVideos[startIdx..<min(startIdx + columnCount, displayVideos.count)])
                        HStack(alignment: .top, spacing: 12) {
                            ForEach(rowVideos) { video in
                                VideoCardView(video: video, compact: false, currentPlaylistId: playlistId, onSelect: {
                                        Task { @MainActor in
                                            let captured = displayVideos
                                            await CurrentQueueStore.shared.replaceAll(with: captured)
                                            let startIdx = video.playlistIndex ?? captured.firstIndex(where: { $0.id == video.id }) ?? 0
                                            selectedVideo = await CurrentQueueStore.shared.videoAt(index: startIdx) ?? video
                                        }
                                    })
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
                            if let last = rowVideos.last { vm.loadMoreIfNeeded(lastVideo: last) }
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                #else
                LazyVGrid(columns: videoGridColumns, spacing: videoGridRowSpacing) {
                    ForEach(displayVideos) { video in
                        VideoCardView(video: video, compact: false, currentPlaylistId: playlistId)
                            .accessibilityIdentifier("video.card.\(video.id)")
                            .onTapGesture {
                                #if os(iOS)
                                Task { @MainActor in
                                    let captured = displayVideos
                                    await CurrentQueueStore.shared.replaceAll(with: captured)
                                    let startIdx = video.playlistIndex ?? captured.firstIndex(where: { $0.id == video.id }) ?? 0
                                    let toPlay = await CurrentQueueStore.shared.videoAt(index: startIdx) ?? video
                                    playerRouter.open(video: toPlay, api: api)
                                }
                                #else
                                Task { @MainActor in
                                    let captured = displayVideos
                                    await CurrentQueueStore.shared.replaceAll(with: captured)
                                    let startIdx = video.playlistIndex ?? captured.firstIndex(where: { $0.id == video.id }) ?? 0
                                    selectedVideo = await CurrentQueueStore.shared.videoAt(index: startIdx) ?? video
                                }
                                #endif
                            }
                            .onAppear { vm.loadMoreIfNeeded(lastVideo: video) }
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                #endif
                if vm.isLoading {
                    ProgressView().frame(maxWidth: .infinity).padding()
                }
            }
        }
        .accessibilityIdentifier("playlistView.feed")
        .refreshable { vm.load(playlistId: playlistId, refresh: true) }
    }

    private var displayVideos: [Video] {
        vm.videos.filter { !store.settings.hideShorts || !$0.isShort }
    }

    private var usesCompactCards: Bool {
        #if os(iOS)
        VideoCardLayoutPolicy.variant(
            for: catalogContext,
            compactSearchCards: store.settings.compactSearchCards,
            compactMediaLibraryCards: store.settings.compactMediaLibraryCards
        ) == .compact
        #else
        store.settings.compactThumbnails
        #endif
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: AppSymbol.stackLayers)
                .font(.system(size: 60))
                .foregroundStyle(.secondary)
            Text("No videos in this playlist")
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
