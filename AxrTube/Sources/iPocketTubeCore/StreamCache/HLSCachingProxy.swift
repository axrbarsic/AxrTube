import Foundation
import os

/// Local caching proxy for HLS playback on weak networks.
///
/// The player loads `http://127.0.0.1:<port>/<session>/master.m3u8`. The
/// proxy exposes one variant (picked for the measured throughput), saves
/// every segment to `StreamSegmentCache`, and runs parallel workers that
/// download the rest of the video ahead of the playhead. When the network
/// drops, the player keeps reading from disk; when it returns, downloading
/// resumes. Segments are keyed by video/rendition/index, so reopening the
/// video later (even offline) reuses them.
public actor HLSCachingProxy {
    public static let shared = HLSCachingProxy(cache: .shared)

    struct Playlist {
        var origin: URL
        var rendition: String
        var segments: [URL] = []
        var starts: [Double] = []
        var durations: [Double] = []
        var done: Set<Int> = []
        var cursor = 0
        var touched = Date.distantPast
        var mime = "video/mp2t"
        var isAudio = false
    }

    struct Session {
        var id: String
        var video: String
        var master: URL
        var headers: [String: String]
        var maxHeight: Int
        /// The exposed variant takes audio from a separate rendition.
        var expectsAudio = false
        var playlists: [Int: Playlist] = [:]
        var others: [Int: (url: URL, name: String)] = [:]
        var retryAt: [String: Date] = [:]
        var attempts: [String: Int] = [:]
    }

    let cache: StreamSegmentCache
    let log = Logger(subsystem: "com.void.ipockettube.app", category: "StreamCache")
    let http: URLSession
    var server: LoopbackHTTPServer?
    var session: Session?
    var workers: [Task<Void, Never>] = []
    var inFlight: [String: Task<(Data, String)?, Never>] = [:]
    var estimate: ThroughputEstimate
    var progressContinuation: AsyncStream<StreamCacheProgress?>.Continuation?
    public static let estimateKey = "axr.streamCache.throughput"
    let estimateStorageKey: String

    public init(cache: StreamSegmentCache, configuration: URLSessionConfiguration = .default,
                estimateKey: String = HLSCachingProxy.estimateKey) {
        self.cache = cache
        self.estimateStorageKey = estimateKey
        let config = configuration
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.timeoutIntervalForRequest = 30
        config.httpMaximumConnectionsPerHost = 8
        http = URLSession(configuration: config)
        estimate = UserDefaults.standard.data(forKey: estimateKey)
            .flatMap { try? JSONDecoder().decode(ThroughputEstimate.self, from: $0) } ?? ThroughputEstimate()
    }

    // MARK: Sessions

    /// Starts caching playback of `videoID`; returns the URL to give AVPlayer,
    /// or nil when the loopback server cannot start (play directly then).
    public func startSession(
        videoID: String, masterURL: URL, headers: [String: String], preferredMaxHeight: Int?
    ) async -> URL? {
        if server == nil {
            server = LoopbackHTTPServer { [weak self] request in
                await self?.handle(request) ?? .init(status: 404)
            }
        }
        guard let port = await server?.start() else { return nil }
        endSession()
        let id = String(UUID().uuidString.prefix(8))
        let budget = estimate.variantBudget(parallelConnections: StreamCachePolicy.prefetchConnections)
        let maxHeight = preferredMaxHeight
            ?? (budget == nil ? StreamCachePolicy.unknownNetworkMaxHeight : StreamCachePolicy.autoMaxHeight)
        session = Session(id: id, video: videoID, master: masterURL, headers: headers, maxHeight: maxHeight)
        await cache.markPlaying(videoID)
        let available = (try? URL(fileURLWithPath: NSHomeDirectory())
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
        let current = await cache.totalBytes()
        await cache.setLimit(StreamCachePolicy.limitBytes(availableCapacity: available, current: current))
        await cache.evictIfNeeded()
        workers = (0..<StreamCachePolicy.prefetchConnections).map { _ in
            Task { [weak self] in await self?.workLoop(session: id) }
        }
        log.notice("[stream-cache] session \(id) video=\(videoID) maxH=\(maxHeight) budget=\(budget ?? -1)")
        return URL(string: "http://127.0.0.1:\(port)/\(id)/master.m3u8")
    }

    /// Stops background downloading (the cache stays on disk).
    public func endSession() {
        workers.forEach { $0.cancel() }
        workers = []
        inFlight.values.forEach { $0.cancel() }
        inFlight = [:]
        session = nil
        notifyProgress()
    }

    /// Deletes every cached stream and forgets what this session had saved.
    public func clearCache() async {
        await cache.removeAll()
        if let ids = session?.playlists.keys {
            for pid in ids { session?.playlists[pid]?.done = [] }
        }
        notifyProgress()
    }

    // MARK: Progress

    /// Pushes a new value the moment a segment is saved (single subscriber).
    public func progressUpdates() -> AsyncStream<StreamCacheProgress?> {
        progressContinuation?.finish()
        let (stream, continuation) = AsyncStream.makeStream(of: StreamCacheProgress?.self,
                                                            bufferingPolicy: .bufferingNewest(1))
        progressContinuation = continuation
        continuation.yield(progress())
        return stream
    }

    func notifyProgress() {
        progressContinuation?.yield(progress())
    }

    /// Marks a segment as on disk only after the write succeeded.
    private func segmentStored(session id: String, playlist pid: Int, index: Int) {
        guard session?.id == id, session?.playlists[pid] != nil else { return }
        session?.playlists[pid]?.done.insert(index)
        notifyProgress()
    }

    public func isProxied(_ url: URL?) -> Bool {
        guard let url, url.host == "127.0.0.1", let id = session?.id else { return false }
        return url.path.hasPrefix("/\(id)/")
    }

    /// Disk coverage of what the player is using right now: the video
    /// rendition intersected with the audio rendition it plays. Nothing is
    /// reported until every rendition needed for playback is known, so the
    /// bar never shows more than can actually play offline.
    public func progress() -> StreamCacheProgress? {
        guard let s = session else { return nil }
        let loaded = s.playlists.values.filter { !$0.segments.isEmpty && $0.touched != .distantPast }
        guard let video = loaded.filter({ !$0.isAudio }).max(by: { $0.touched < $1.touched }) else { return nil }
        let audio = loaded.filter(\.isAudio).max(by: { $0.touched < $1.touched })
        if s.expectsAudio && audio == nil { return nil }
        var ranges = StreamCacheCoverage.ranges(starts: video.starts, durations: video.durations, done: video.done)
        var complete = video.done.count >= video.segments.count
        if let audio {
            ranges = StreamCacheCoverage.intersect(
                ranges, StreamCacheCoverage.ranges(starts: audio.starts, durations: audio.durations, done: audio.done)
            )
            complete = complete && audio.done.count >= audio.segments.count
        }
        return StreamCacheProgress(ranges: ranges, duration: video.durations.reduce(0, +), isComplete: complete)
    }

    // MARK: Origin

    func fetch(_ url: URL, headers: [String: String]) async throws -> (Data, String) {
        var request = URLRequest(url: url)
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        request.assumesHTTP3Capable = true
        let started = Date()
        let (data, response) = try await http.data(for: request)
        guard let status = (response as? HTTPURLResponse)?.statusCode, (200...299).contains(status) else {
            throw URLError(.badServerResponse)
        }
        record(bytes: data.count, seconds: Date().timeIntervalSince(started))
        return (data, response.mimeType ?? "application/octet-stream")
    }

    private func record(bytes: Int, seconds: TimeInterval) {
        estimate.record(bytes: bytes, seconds: seconds)
        if let data = try? JSONEncoder().encode(estimate) {
            UserDefaults.standard.set(data, forKey: estimateStorageKey)
        }
    }

    // MARK: Segments

    static func key(_ playlist: Int, _ index: Int) -> String { "\(playlist):\(index)" }

    /// Disk, then a running download, then a new download. Deduplicated.
    func loadSegment(session id: String, playlist pid: Int, index: Int) async -> (Data, String)? {
        guard let s = session, s.id == id, let pl = s.playlists[pid], index < pl.segments.count else { return nil }
        let key = Self.key(pid, index)
        if let running = inFlight[key] { return await running.value }
        let url = pl.segments[index], headers = s.headers, video = s.video
        let rendition = pl.rendition, cachedMime = pl.mime
        // Registered before any suspension so concurrent callers share it.
        let task = Task<(Data, String)?, Never> { [weak self] in
            guard let self else { return nil }
            if let data = await self.cache.segment(video: video, rendition: rendition, index: index) {
                return (data, cachedMime)
            }
            guard let (data, mime) = try? await self.fetch(url, headers: headers) else { return nil }
            let stored = await self.cache.storeSegment(data, video: video, rendition: rendition, index: index)
            if stored { await self.segmentStored(session: id, playlist: pid, index: index) }
            return (data, mime)
        }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil
        guard session?.id == id else { return result }
        if let (_, mime) = result {
            if session?.playlists[pid]?.mime != mime, let s = session, let pl = s.playlists[pid] {
                session?.playlists[pid]?.mime = mime
                await cache.storeNamed(Data(mime.utf8), video: s.video, name: "mime-" + pl.rendition)
            }
            session?.attempts[key] = nil
            session?.retryAt[key] = nil
        } else {
            let attempt = (session?.attempts[key] ?? 0) + 1
            session?.attempts[key] = attempt
            session?.retryAt[key] = Date().addingTimeInterval(StreamCachePolicy.retryDelay(attempt: attempt))
        }
        return result
    }

    // MARK: Prefetch workers

    /// Next missing segment, preferring the rendition that is furthest
    /// behind in time so video and audio stay level.
    func claimJob(session id: String) -> (playlist: Int, index: Int)? {
        guard let s = session, s.id == id else { return nil }
        let now = Date()
        var best: (playlist: Int, index: Int, start: Double)?
        for (pid, pl) in s.playlists where now.timeIntervalSince(pl.touched) < 600 {
            let busy = Set(inFlight.keys.compactMap { k -> Int? in
                let parts = k.split(separator: ":")
                return parts.first == Substring(String(pid)) ? Int(parts[1]) : nil
            })
            let waiting = Set(s.retryAt.compactMap { k, at -> Int? in
                let parts = k.split(separator: ":")
                return at > now && parts.first == Substring(String(pid)) ? Int(parts[1]) : nil
            })
            guard let index = SegmentPrefetchPlanner.next(
                count: pl.segments.count, cursor: pl.cursor, done: pl.done,
                busy: busy.union(waiting), slots: 1
            ).first else { continue }
            let start = index < pl.starts.count ? pl.starts[index] : 0
            if best == nil || start < best!.start { best = (pid, index, start) }
        }
        return best.map { ($0.playlist, $0.index) }
    }

    private func workLoop(session id: String) async {
        while !Task.isCancelled, session?.id == id {
            guard NetworkPathObserver.shared.isAvailable, let job = claimJob(session: id) else {
                try? await Task.sleep(for: .seconds(1))
                continue
            }
            if await loadSegment(session: id, playlist: job.playlist, index: job.index) == nil {
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }
}
