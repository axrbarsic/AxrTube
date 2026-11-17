import Foundation

/// One row of «Скачанные», whatever stored it: a video saved from the
/// stream cache or a legacy file download (video or audio-only).
public struct DownloadLibraryItem: Identifiable, Equatable, Sendable {
    public enum Source: Equatable, Sendable {
        case saved
        case file(OfflineMediaKind)
        /// In YouTube «Смотреть позже», not on this phone yet.
        case watchLater
    }

    public enum State: Equatable, Sendable {
        case ready
        case downloading(Double)
        case paused(Double)
        case failed
        case notDownloaded
    }

    public var id: String
    public var videoID: String
    public var title: String
    public var channelTitle: String
    public var thumbnailURL: URL?
    public var duration: Double
    public var source: Source
    public var state: State
    public var bytes: Int64
    public var date: Date?
    /// A save from the stream cache that holds only the audio track.
    public var savedAudioOnly = false
    public var watched = false

    public var isAudio: Bool { source == .file(.audio) || savedAudioOnly }
    public var isInProgress: Bool {
        switch state {
        case .downloading, .paused, .failed: true
        default: false
        }
    }
    public var isPlayable: Bool { state == .ready || source == .saved || source == .watchLater }
}

public enum DownloadLibraryList {
    /// Unified, newest first; unfinished downloads on top like YouTube.
    public static func items(saved: [PinnedStream], files: [DownloadedVideo], watchLater: [Video] = []) -> [DownloadLibraryItem] {
        var result = saved.map { s in
            DownloadLibraryItem(
                id: "saved::\(s.videoId)", videoID: s.videoId, title: s.title, channelTitle: s.channelTitle,
                thumbnailURL: s.thumbnailURL, duration: s.duration, source: .saved,
                state: s.isComplete ? .ready : .downloading(s.progress), bytes: s.bytes, date: s.pinnedAt,
                savedAudioOnly: s.isAudioOnly, watched: s.watchedAt != nil
            )
        }
        let known = Set(saved.map(\.videoId)).union(files.map(\.videoId))
        for (rank, v) in watchLater.enumerated() where !known.contains(v.id) {
            result.append(DownloadLibraryItem(
                id: "wl::\(v.id)", videoID: v.id, title: v.title, channelTitle: v.channelTitle,
                thumbnailURL: v.thumbnailURL, duration: v.duration ?? 0, source: .watchLater,
                state: .notDownloaded, bytes: 0,
                // Keeps YouTube's order below everything on the phone.
                date: Date(timeIntervalSince1970: Double(-rank))
            ))
        }
        for f in files where f.status != .cancelled {
            let state: DownloadLibraryItem.State
            switch f.status {
            case .completed: state = .ready
            case .failed: state = .failed
            case .paused: state = .paused(f.progress)
            default: state = .downloading(f.progress)
            }
            result.append(DownloadLibraryItem(
                id: "file::\(f.id)", videoID: f.videoId, title: f.title, channelTitle: f.channelTitle,
                thumbnailURL: f.thumbnailURL, duration: f.duration, source: .file(f.kind),
                state: state, bytes: f.fileSizeBytes, date: f.downloadedAt
            ))
        }
        return result.sorted { a, b in
            let aActive = a.isInProgress, bActive = b.isInProgress
            if aActive != bActive { return aActive }
            return (a.date ?? .distantFuture) > (b.date ?? .distantFuture)
        }
    }

    /// Filter chips of «Сохранённое».
    public enum Filter: String, CaseIterable, Sendable {
        case all, unwatched, downloaded, audio

        public var title: String {
            switch self {
            case .all: "Все"
            case .unwatched: "Не просмотрено"
            case .downloaded: "Скачано"
            case .audio: "Только звук"
            }
        }

        public func includes(_ item: DownloadLibraryItem) -> Bool {
            switch self {
            case .all: true
            case .unwatched: !item.watched
            case .downloaded: item.state == .ready
            case .audio: item.isAudio
            }
        }
    }

    /// Status line under the title.
    public static func status(_ item: DownloadLibraryItem) -> String {
        let size = ByteCountFormatter.string(fromByteCount: item.bytes, countStyle: .file)
        let kind = item.isAudio ? "Аудио" : "Видео"
        switch item.state {
        case .ready:
            let base = item.bytes > 0 ? "\(kind) · \(size)" : kind
            return item.watched ? base + " · просмотрено" : base
        case .downloading(let p): return "Скачивается · \(Int(p * 100))%"
        case .paused(let p): return "Пауза · \(Int(p * 100))%"
        case .failed: return "Не удалось скачать"
        case .notDownloaded: return "Смотреть позже · не скачано"
        }
    }
}
