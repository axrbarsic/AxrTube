import Foundation

/// One row of «Скачанные», whatever stored it: a video saved from the
/// stream cache or a legacy file download (video or audio-only).
public struct DownloadLibraryItem: Identifiable, Equatable, Sendable {
    public enum Source: Equatable, Sendable {
        case saved
        case file(OfflineMediaKind)
    }

    public enum State: Equatable, Sendable {
        case ready
        case downloading(Double)
        case paused(Double)
        case failed
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

    public var isAudio: Bool { source == .file(.audio) }
    public var isPlayable: Bool { state == .ready || source == .saved }
}

public enum DownloadLibraryList {
    /// Unified, newest first; unfinished downloads on top like YouTube.
    public static func items(saved: [PinnedStream], files: [DownloadedVideo]) -> [DownloadLibraryItem] {
        var result = saved.map { s in
            DownloadLibraryItem(
                id: "saved::\(s.videoId)", videoID: s.videoId, title: s.title, channelTitle: s.channelTitle,
                thumbnailURL: s.thumbnailURL, duration: s.duration, source: .saved,
                state: s.isComplete ? .ready : .downloading(s.progress), bytes: s.bytes, date: s.pinnedAt
            )
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
            let aActive = a.state != .ready, bActive = b.state != .ready
            if aActive != bActive { return aActive }
            return (a.date ?? .distantFuture) > (b.date ?? .distantFuture)
        }
    }

    /// Status line under the title.
    public static func status(_ item: DownloadLibraryItem) -> String {
        let size = ByteCountFormatter.string(fromByteCount: item.bytes, countStyle: .file)
        let kind = item.isAudio ? "Аудио" : "Видео"
        switch item.state {
        case .ready: return item.bytes > 0 ? "\(kind) · \(size)" : kind
        case .downloading(let p): return "Скачивается · \(Int(p * 100))%"
        case .paused(let p): return "Пауза · \(Int(p * 100))%"
        case .failed: return "Не удалось скачать"
        }
    }
}
