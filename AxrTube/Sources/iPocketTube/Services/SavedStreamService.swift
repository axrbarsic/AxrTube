import Foundation
import Observation
import iPocketTubeCore

/// «Сохранить»: one action that adds the video to YouTube «Смотреть позже»
/// (when signed in) and keeps it on the phone, built from the stream cache —
/// what was already downloaded while watching is kept, the rest is completed
/// in the background. «Смотреть позже» added on other devices is mirrored
/// and, optionally, downloaded automatically.
@MainActor
@Observable
final class SavedStreamService {
    static let shared = SavedStreamService()

    /// YouTube «Смотреть позже» as last fetched (newest first).
    private(set) var watchLater: [Video] = []
    private(set) var isSyncing = false

    private var configured = false
    private var api: InnerTubeAPI?
    private var settings: () -> AppSettings = { AppSettings() }
    private var signedIn: () -> Bool = { false }
    private var lastSync: Date?

    /// How many of the newest «Смотреть позже» videos are downloaded automatically.
    static let autoDownloadLimit = 8

    // MARK: Lifecycle

    /// Wires URL refresh, finishes pending saves and mirrors «Смотреть позже».
    func start(api: InnerTubeAPI, settings: @escaping () -> AppSettings, signedIn: @escaping () -> Bool) {
        self.api = api
        self.settings = settings
        self.signedIn = signedIn
        if !configured {
            configured = true
            Task {
                await PinnedStreamCompleter.shared.setResolver { videoID in
                    guard let info = try? await api.fetchStartupPlayerInfo(videoId: videoID),
                          let hls = info.hlsURL else { return nil }
                    return StreamSource(master: hls, headers: [
                        "User-Agent": InnerTubeClients.Web.userAgent,
                        "Origin": "https://www.youtube.com",
                        "Referer": "https://www.youtube.com/",
                    ])
                }
            }
        }
        resume()
        Task { await syncWatchLater() }
    }

    /// Restarts background completion (also after the network changes).
    func resume() {
        let library = PinnedStreamLibrary.shared
        guard !library.pending.isEmpty else { return }
        Task {
            await PinnedStreamCompleter.shared.start(
                pending: {
                    await MainActor.run {
                        library.pending(onMobileNetwork: NetworkPathObserver.shared.isMobile,
                                        videoOverWiFiOnly: SavedStreamService.shared.settings().downloadsWiFiOnly)
                    }
                },
                report: { id, progress, complete in
                    await library.update(id, progress: progress, isComplete: complete)
                }
            )
        }
    }

    // MARK: Save / remove

    func isSaved(_ videoID: String) -> Bool { PinnedStreamLibrary.shared.entry(videoID) != nil }

    /// Saves to the phone and to «Смотреть позже». Pass the playing
    /// session's progress so a watched video is saved instantly.
    func save(_ video: Video, audioOnly: Bool, cachedFraction: Double = 0, isComplete: Bool = false) {
        Task {
            await PinnedStreamLibrary.shared.pin(video, progress: cachedFraction, isComplete: isComplete, audioOnly: audioOnly)
            resume()
        }
        if signedIn(), !watchLater.contains(where: { $0.id == video.id }), let api {
            watchLater.insert(video, at: 0)
            Task { try? await api.addToWatchLater(videoId: video.id) }
        }
    }

    /// Removes from the phone and from «Смотреть позже».
    func remove(_ videoID: String) {
        Task { await PinnedStreamLibrary.shared.remove(videoID) }
        if watchLater.contains(where: { $0.id == videoID }), let api {
            watchLater.removeAll { $0.id == videoID }
            Task { try? await api.removeFromWatchLater(videoId: videoID) }
        }
    }

    /// Download a «Смотреть позже» video that is not on the phone yet.
    func download(_ video: Video) {
        save(video, audioOnly: wantsAudioOnlyDownload)
    }

    /// New downloads follow «Экономия трафика».
    var wantsAudioOnlyDownload: Bool {
        let s = settings()
        return DataSaverPolicy.streamsAudioOnly(mode: s.dataSaver, audioOnlySetting: s.audioOnlyMode,
                                                onMobileNetwork: NetworkPathObserver.shared.isMobile, videoRequested: false)
    }

    // MARK: Watched

    /// Called while playing; marks a saved video watched near its end and,
    /// if asked, removes it from the phone.
    func playbackProgress(videoID: String, time: Double, duration: Double) {
        guard duration > 30, time / duration >= 0.92,
              let entry = PinnedStreamLibrary.shared.entry(videoID), entry.watchedAt == nil else { return }
        PinnedStreamLibrary.shared.markWatched(videoID)
        if settings().deleteSavedAfterWatching {
            // Keep it until playback moves on; removing the files mid-play would cut the ending.
            pendingAutoDelete.insert(videoID)
        }
    }

    private var pendingAutoDelete: Set<String> = []

    /// The player moved to another video: apply «Удалять после просмотра».
    func playbackMoved(from videoID: String?) {
        guard let videoID, pendingAutoDelete.remove(videoID) != nil else { return }
        remove(videoID)
    }

    // MARK: «Смотреть позже»

    func syncWatchLater(force: Bool = false) async {
        guard signedIn(), let api, !isSyncing else { return }
        if !force, let lastSync, Date().timeIntervalSince(lastSync) < 120 { return }
        isSyncing = true
        defer { isSyncing = false }
        guard let group = try? await api.fetchPlaylistVideos(playlistId: "WL", continuationToken: nil) else { return }
        lastSync = Date()
        watchLater = group.videos.filter { !$0.id.isEmpty }
        guard settings().watchLaterAutoDownload else { return }
        let library = PinnedStreamLibrary.shared
        let audioOnly = wantsAudioOnlyDownload
        for video in watchLater.prefix(Self.autoDownloadLimit) where library.entry(video.id) == nil {
            await library.pin(video, progress: 0, isComplete: false, audioOnly: audioOnly)
        }
        resume()
    }
}
