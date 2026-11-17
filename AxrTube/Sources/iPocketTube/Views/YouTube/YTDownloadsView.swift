#if os(iOS)
import SwiftUI
import iPocketTubeCore

/// «Сохранённое» on iPhone: YouTube «Смотреть позже» merged with what is on
/// the phone — saves from the stream cache and older file downloads — in
/// one YouTube-style list with filters.
struct YTDownloadsView: View {
    @Environment(DownloadStore.self) private var downloadStore
    @Environment(VideoDownloadService.self) private var downloadService
    @Environment(AudioDownloadService.self) private var audioDownloadService
    @Environment(SettingsStore.self) private var settingsStore
    @Environment(PlayerRouter.self) private var playerRouter
    @Environment(PlayerStateStore.self) private var playerState
    @Environment(\.innerTubeAPI) private var api
    @State private var library = PinnedStreamLibrary.shared
    @State private var pendingDelete: DownloadLibraryItem?
    @State private var confirmDeleteAll = false
    @State private var transcriptVideo: Video?
    @State private var saved = SavedStreamService.shared
    @State private var filter: DownloadLibraryList.Filter = .all

    private var items: [DownloadLibraryItem] {
        DownloadLibraryList.items(saved: library.entries, files: downloadStore.entries, watchLater: saved.watchLater)
    }

    var body: some View {
        let all = items
        let items = all.filter(filter.includes)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if all.isEmpty {
                    empty
                } else {
                    header(all)
                    chips
                    if items.isEmpty {
                        Text("Ничего не найдено")
                            .font(.system(size: 14))
                            .foregroundStyle(YTColor.secondaryText)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                    }
                    ForEach(items) { item in
                        let playing = playerState.currentVideo?.id == item.videoID
                        YTDownloadRow(item: item, isNowPlaying: playing, actions: actions(for: item))
                        if playing { YTDownloadNowPlaying(vm: playerState.vm) }
                    }
                }
            }
            .padding(.bottom, 24)
        }
        .background(YTColor.background)
        .refreshable { await saved.syncWatchLater(force: true) }
        .task { await saved.syncWatchLater() }
        .navigationTitle("Сохранённое")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            Menu {
                NavigationLink {
                    YTStorageSettingsView()
                } label: {
                    Label("Хранилище", systemImage: "internaldrive")
                }
                if !all.isEmpty {
                    Button("Удалить всё с телефона", role: .destructive) { confirmDeleteAll = true }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityIdentifier("saved.menu")
        }
        .confirmationDialog("Удалить «\(pendingDelete?.title ?? "")»?", isPresented: Binding(
            get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }
        ), titleVisibility: .visible) {
            Button("Удалить", role: .destructive) {
                if let item = pendingDelete { delete([item]) }
                pendingDelete = nil
            }
            Button("Отмена", role: .cancel) { pendingDelete = nil }
        }
        .confirmationDialog("Удалить все ролики с телефона?", isPresented: $confirmDeleteAll, titleVisibility: .visible) {
            Button("Удалить все", role: .destructive) { delete(all.filter { $0.source != .watchLater }, keepWatchLater: true) }
            Button("Отмена", role: .cancel) {}
        }
        .fullScreenCover(item: $transcriptVideo) { video in
            if video.id != playerState.currentVideo?.id {
                SavedVideoTranscriptPanel(video: video, api: api,
                                          translation: playerState.vm.russianTranscriptTranslation) {
                    transcriptVideo = nil
                }
                .preferredColorScheme(settingsStore.settings.appearance.colorScheme)
            } else {
                CurrentPlaybackTranscriptPanel { transcriptVideo = nil }
            }
        }
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(DownloadLibraryList.Filter.allCases, id: \.self) { item in
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

    private func header(_ items: [DownloadLibraryItem]) -> some View {
        let bytes = items.reduce(Int64(0)) { $0 + $1.bytes }
        return Text("\(items.count) \(Self.videosWord(items.count)) · \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))")
            .font(.system(size: 13))
            .foregroundStyle(YTColor.secondaryText)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
    }

    private var empty: some View {
        VStack(spacing: 12) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(YTColor.secondaryText)
            Text("Здесь пусто")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(YTColor.primaryText)
            Text("Нажмите «Сохранить» под видео: ролик попадёт в «Смотреть позже» и будет доступен без интернета.")
                .font(.system(size: 14))
                .foregroundStyle(YTColor.secondaryText)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 32)
        .padding(.top, 120)
    }

    // MARK: Actions

    private func actions(for item: DownloadLibraryItem) -> YTDownloadRow.Actions {
        let file = fileEntry(item)
        return YTDownloadRow.Actions(
            play: { play(item, file: file, withVideo: false) },
            watchVideo: item.source == .file(.audio) ? nil : { play(item, file: file, withVideo: true) },
            transcript: { transcriptVideo = file?.video ?? library.entry(item.videoID)?.video },
            pauseOrResume: file.flatMap { entry in
                switch item.state {
                case .downloading where entry.kind == .video: { downloadService.pause(videoID: entry.videoId) }
                case .paused: { retry(entry) }
                default: nil
                }
            },
            retry: item.state == .failed ? file.map { entry in { retry(entry) } } : nil,
            download: item.source == .watchLater ? { saved.download(watchLaterVideo(item)) } : nil,
            delete: { pendingDelete = item }
        )
    }

    private func fileEntry(_ item: DownloadLibraryItem) -> DownloadedVideo? {
        guard case .file(let kind) = item.source else { return nil }
        return downloadStore.entry(videoId: item.videoID, kind: kind)
    }

    /// Tap plays sound only and stays in the list; «Смотреть видео» opens
    /// the watch page with the picture.
    private func play(_ item: DownloadLibraryItem, file: DownloadedVideo?, withVideo: Bool) {
        iPocketTubeHaptics.shared.perform(.downloadSelection)
        guard let video = file?.video ?? library.entry(item.videoID)?.video
                ?? (item.source == .watchLater ? watchLaterVideo(item) : nil) else { return }
        if withVideo {
            playerRouter.openWithVideo(video: video)
        } else {
            playerRouter.playAudio(video: video)
        }
    }

    private func retry(_ entry: DownloadedVideo) {
        iPocketTubeHaptics.shared.perform(.downloadRetry)
        if entry.kind == .audio {
            var video = entry.video
            video.localFileURL = nil
            audioDownloadService.download(video: video)
        } else {
            downloadService.retry(entry: entry, storageLimitMB: settingsStore.settings.offlineStorageLimitMB)
        }
    }

    private func watchLaterVideo(_ item: DownloadLibraryItem) -> Video {
        saved.watchLater.first { $0.id == item.videoID }
            ?? Video(id: item.videoID, title: item.title, channelTitle: item.channelTitle,
                     thumbnailURL: item.thumbnailURL, duration: item.duration)
    }

    /// Removes from «Сохранённое» (phone and «Смотреть позже»). `keepWatchLater`
    /// only frees the phone ("Удалить всё с телефона").
    private func delete(_ items: [DownloadLibraryItem], keepWatchLater: Bool = false) {
        iPocketTubeHaptics.shared.perform(.primaryAction)
        let files = items.compactMap(fileEntry)
        for item in items where item.source == .saved || item.source == .watchLater {
            if playerState.currentVideo?.id == item.videoID, item.source == .saved { playerState.stop(discardItem: true) }
            if keepWatchLater {
                Task { await PinnedStreamLibrary.shared.remove(item.videoID) }
            } else {
                saved.remove(item.videoID)
            }
        }
        guard !files.isEmpty else { return }
        let ids = Set(files.map(\.videoId))
        OfflineRemovalTransaction.perform(
            removingVideoIDs: ids,
            currentVideoID: playerState.currentVideo?.id,
            stopPlayback: { playerState.stop(discardItem: true) },
            cancelDownloads: { downloadService.cancel(videoIDs: ids) },
            removeFiles: { files.forEach { downloadStore.remove(videoId: $0.videoId, kind: $0.kind) } }
        )
    }

    static func videosWord(_ n: Int) -> String {
        let mod10 = n % 10, mod100 = n % 100
        if mod10 == 1 && mod100 != 11 { return "ролик" }
        if (2...4).contains(mod10) && !(12...14).contains(mod100) { return "ролика" }
        return "роликов"
    }
}
#endif
