import Foundation
import Observation

/// A video the user saved with «Скачать», built from the stream cache.
public struct PinnedStream: Codable, Identifiable, Equatable, Sendable {
    public var id: String { videoId }
    public let videoId: String
    public let title: String
    public let channelTitle: String
    public let thumbnailURL: URL?
    public let duration: Double
    public let pinnedAt: Date
    public var progress: Double
    public var isComplete: Bool
    public var bytes: Int64

    public var video: Video {
        Video(id: videoId, title: title, channelTitle: channelTitle, thumbnailURL: thumbnailURL, duration: duration)
    }
}

/// Saved videos. Pinning moves what is cached into permanent storage, so a
/// watched video is saved without downloading it again.
@MainActor
@Observable
public final class PinnedStreamLibrary {
    public static let shared = PinnedStreamLibrary(
        fileURL: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AxrPinnedStreams.json"),
        cache: .shared
    )

    public private(set) var entries: [PinnedStream] = []
    private let fileURL: URL
    private let cache: StreamSegmentCache

    public init(fileURL: URL, cache: StreamSegmentCache) {
        self.fileURL = fileURL
        self.cache = cache
        if let data = try? Data(contentsOf: fileURL),
           let stored = try? JSONDecoder().decode([PinnedStream].self, from: data) {
            entries = stored
        }
    }

    public func entry(_ videoID: String) -> PinnedStream? {
        entries.first { $0.videoId == videoID }
    }

    public var pending: [String] {
        entries.filter { !$0.isComplete }.map(\.videoId)
    }

    public func pin(_ video: Video, progress: Double, isComplete: Bool) async {
        guard entry(video.id) == nil else { return }
        await cache.pin(video.id)
        entries.insert(PinnedStream(
            videoId: video.id, title: video.title, channelTitle: video.channelTitle,
            thumbnailURL: video.thumbnailURL, duration: video.duration ?? 0, pinnedAt: Date(),
            progress: progress, isComplete: isComplete, bytes: await cache.pinnedBytes(video.id)
        ), at: 0)
        save()
    }

    public func remove(_ videoID: String) async {
        entries.removeAll { $0.videoId == videoID }
        save()
        await cache.unpin(videoID)
    }

    public func update(_ videoID: String, progress: Double, isComplete: Bool) async {
        guard let index = entries.firstIndex(where: { $0.videoId == videoID }) else { return }
        let clamped = min(max(progress, 0), 1)
        guard entries[index].progress != clamped || entries[index].isComplete != isComplete else { return }
        // Re-measure disk usage on completion and every 5 %, not per segment.
        let remeasure = isComplete || Int(clamped * 20) != Int(entries[index].progress * 20)
        entries[index].progress = clamped
        entries[index].isComplete = isComplete
        if remeasure {
            let bytes = await cache.pinnedBytes(videoID)
            if let i = entries.firstIndex(where: { $0.videoId == videoID }) { entries[i].bytes = bytes }
        }
        save()
    }

    public var totalBytes: Int64 { entries.reduce(0) { $0 + $1.bytes } }

    private func save() {
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(entries) { try? data.write(to: fileURL, options: .atomic) }
    }
}
