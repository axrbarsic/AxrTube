import Foundation

/// Disk store for streamed HLS data, keyed by video, rendition and segment
/// index so a later session (with freshly signed URLs) reuses what earlier
/// sessions downloaded. Least-recently-played videos are evicted first.
public actor StreamSegmentCache {
    public static let shared = StreamSegmentCache(
        root: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AxrStreamCache", isDirectory: true)
    )

    public let root: URL
    /// Upper bound for all cached streams.
    public var limitBytes: Int64
    private let fm = FileManager.default
    private var protectedVideo: String?

    public init(root: URL, limitBytes: Int64 = 2 * 1024 * 1024 * 1024) {
        self.root = root
        self.limitBytes = limitBytes
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    public func setLimit(_ bytes: Int64) { limitBytes = bytes }

    // MARK: Paths

    static func safe(_ component: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let cleaned = String(component.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
        return cleaned.isEmpty ? "_" : String(cleaned.prefix(64))
    }

    private func videoDir(_ video: String) -> URL {
        root.appendingPathComponent(Self.safe(video), isDirectory: true)
    }

    private func segmentURL(video: String, rendition: String, index: Int) -> URL {
        videoDir(video)
            .appendingPathComponent(Self.safe(rendition), isDirectory: true)
            .appendingPathComponent("\(index).seg")
    }

    private func namedURL(video: String, name: String) -> URL {
        videoDir(video).appendingPathComponent(Self.safe(name) + ".dat")
    }

    // MARK: Segments

    public func segment(video: String, rendition: String, index: Int) -> Data? {
        try? Data(contentsOf: segmentURL(video: video, rendition: rendition, index: index))
    }

    public func hasSegment(video: String, rendition: String, index: Int) -> Bool {
        fm.fileExists(atPath: segmentURL(video: video, rendition: rendition, index: index).path)
    }

    public func cachedIndices(video: String, rendition: String) -> Set<Int> {
        let dir = videoDir(video).appendingPathComponent(Self.safe(rendition), isDirectory: true)
        let names = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        return Set(names.compactMap { $0.hasSuffix(".seg") ? Int($0.dropLast(4)) : nil })
    }

    public func storeSegment(_ data: Data, video: String, rendition: String, index: Int) {
        let url = segmentURL(video: video, rendition: rendition, index: index)
        write(data, to: url)
    }

    // MARK: Playlists and other small files

    public func named(video: String, name: String) -> Data? {
        try? Data(contentsOf: namedURL(video: video, name: name))
    }

    public func storeNamed(_ data: Data, video: String, name: String) {
        write(data, to: namedURL(video: video, name: name))
    }

    private func write(_ data: Data, to url: URL) {
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Atomic: a half-written file must never be served as a segment.
        try? data.write(to: url, options: .atomic)
    }

    // MARK: Eviction

    /// Marks a video as playing: it is never evicted and becomes most recent.
    public func markPlaying(_ video: String) {
        protectedVideo = video
        let dir = videoDir(video)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: dir.path)
    }

    public func totalBytes() -> Int64 {
        directorySizes().reduce(0) { $0 + $1.bytes }
    }

    /// Deletes least-recently-played videos until the cache fits the limit.
    public func evictIfNeeded() {
        var entries = directorySizes()
        var total = entries.reduce(0) { $0 + $1.bytes }
        guard total > limitBytes else { return }
        entries.sort { $0.date < $1.date }
        for entry in entries where total > limitBytes {
            if entry.url.lastPathComponent == protectedVideo.map(Self.safe) { continue }
            try? fm.removeItem(at: entry.url)
            total -= entry.bytes
        }
    }

    public func removeAll() {
        try? fm.removeItem(at: root)
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    private func directorySizes() -> [(url: URL, date: Date, bytes: Int64)] {
        let videos = (try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]
        )) ?? []
        return videos.map { dir in
            let date = (try? dir.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            var bytes: Int64 = 0
            if let walker = fm.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey]) {
                for case let file as URL in walker {
                    bytes += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
                }
            }
            return (dir, date, bytes)
        }
    }
}
