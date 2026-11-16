#if os(iOS)
import SwiftUI
import iPocketTubeCore

/// «Скачанные» on iPhone: one YouTube-style list for videos saved from the
/// stream cache and for file downloads (video and audio-only).
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

    private var items: [DownloadLibraryItem] {
        DownloadLibraryList.items(saved: library.entries, files: downloadStore.entries)
    }

    var body: some View {
        let items = items
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if items.isEmpty {
                    empty
                } else {
                    header(items)
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
        .navigationTitle("Скачанные")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            if !items.isEmpty {
                Menu {
                    Button("Удалить все скачанные", role: .destructive) { confirmDeleteAll = true }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
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
        .confirmationDialog("Удалить все скачанные ролики?", isPresented: $confirmDeleteAll, titleVisibility: .visible) {
            Button("Удалить все", role: .destructive) { delete(items) }
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
            Text("Нет скачанных роликов")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(YTColor.primaryText)
            Text("Нажмите «Скачать» под видео — ролик будет доступен без интернета.")
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
        guard let video = file?.video ?? library.entry(item.videoID)?.video else { return }
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

    private func delete(_ items: [DownloadLibraryItem]) {
        iPocketTubeHaptics.shared.perform(.primaryAction)
        let files = items.compactMap(fileEntry)
        for item in items where item.source == .saved {
            if playerState.currentVideo?.id == item.videoID { playerState.stop(discardItem: true) }
            SavedStreamService.remove(item.videoID)
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
