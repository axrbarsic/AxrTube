import Foundation
import os

/// Finishes saved videos in the background once the player has moved on.
/// While a saved video is playing, the proxy downloads it; afterwards this
/// downloads the missing segments of the same renditions into permanent
/// storage, refreshing expired YouTube URLs through `resolver`.
public actor PinnedStreamCompleter {
    public static let shared = PinnedStreamCompleter(cache: .shared, proxy: .shared)

    /// Fresh stream source for a video (new signed master URL).
    public typealias Resolver = @Sendable (String) async -> StreamSource?
    /// Videos still to finish, and progress reporting back to the library.
    public typealias Pending = @Sendable () async -> [String]
    public typealias Report = @Sendable (String, Double, Bool) async -> Void

    private let cache: StreamSegmentCache
    private let proxy: HLSCachingProxy
    private let http: URLSession
    private let log = Logger(subsystem: "com.void.ipockettube.app", category: "StreamCache")
    private var loop: Task<Void, Never>?
    private var resolver: Resolver?
    private var retryAfter: [String: Date] = [:]

    public init(cache: StreamSegmentCache, proxy: HLSCachingProxy, configuration: URLSessionConfiguration = .default) {
        self.cache = cache
        self.proxy = proxy
        let config = configuration
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.timeoutIntervalForRequest = 30
        http = URLSession(configuration: config)
    }

    public func setResolver(_ resolver: @escaping Resolver) { self.resolver = resolver }

    /// Starts (or keeps) the background loop.
    public func start(pending: @escaping Pending, report: @escaping Report) {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            await self?.run(pending: pending, report: report)
            await self?.finished()
        }
    }

    private func finished() { loop = nil }

    private func run(pending: Pending, report: Report) async {
        while !Task.isCancelled {
            let ids = await pending()
            if ids.isEmpty { return }
            let active = await proxy.activeVideoID
            let now = Date()
            guard NetworkPathObserver.shared.isAvailable,
                  let next = ids.first(where: { $0 != active && (retryAfter[$0] ?? .distantPast) <= now }) else {
                try? await Task.sleep(for: .seconds(3))
                continue
            }
            if await complete(next, report: report) == false {
                retryAfter[next] = Date().addingTimeInterval(60)
            }
        }
    }

    private struct Rendition {
        var key: String
        var segments: [URL]
    }

    /// True when finished or handed back to the proxy; false to retry later.
    private func complete(_ video: String, report: Report) async -> Bool {
        if await storedRenditions(video).isEmpty, await !bootstrap(video) { return false }
        guard let sourceData = await cache.named(video: video, name: StreamSource.fileName),
              var source = try? JSONDecoder().decode(StreamSource.self, from: sourceData) else { return false }
        var renditions = await storedRenditions(video)
        guard !renditions.isEmpty else { return false }
        var refreshed = false
        while !Task.isCancelled {
            if await proxy.activeVideoID == video { return true }
            var failed = false
            for rendition in renditions {
                failed = await download(video, rendition, source: source, all: renditions, report: report) || failed
            }
            let (progress, complete) = await state(video, renditions)
            await report(video, progress, complete)
            if complete { log.notice("[pinned] \(video) complete"); return true }
            guard failed, !refreshed, let resolver, let fresh = await resolver(video),
                  let updated = await refresh(video, keys: renditions.map(\.key), source: fresh) else { return false }
            source = fresh
            renditions = updated
            refreshed = true
        }
        return false
    }

    /// A video saved without being played: resolve its stream and store the
    /// playlists (no segments yet) the same way a playback session would.
    private func bootstrap(_ video: String) async -> Bool {
        guard let resolver, let source = await resolver(video) else { return false }
        let audioOnly = await cache.named(video: video, name: PinnedStreamLibrary.audioOnlyMarker)
            .flatMap { String(data: $0, encoding: .utf8) } == "1"
        await proxy.prefetchHead(videoID: video, masterURL: source.master, headers: source.headers,
                                 preferredMaxHeight: nil, seconds: 0, audioOnly: audioOnly)
        let ok = await !storedRenditions(video).isEmpty
        log.notice("[pinned] \(video) bootstrap \(ok ? "ok" : "failed")")
        return ok
    }

    /// Downloads missing segments with three connections. Returns true if
    /// any segment failed.
    private func download(_ video: String, _ r: Rendition, source: StreamSource, all: [Rendition], report: Report) async -> Bool {
        let done = await cache.cachedIndices(video: video, rendition: r.key)
        let missing = r.segments.indices.filter { !done.contains($0) }
        var failed = false
        var iterator = missing.makeIterator()
        await withTaskGroup(of: Bool.self) { group in
            func add() -> Bool {
                guard let index = iterator.next() else { return false }
                let url = r.segments[index]
                group.addTask { [http, cache] in
                    var request = URLRequest(url: url)
                    source.headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
                    request.assumesHTTP3Capable = true
                    guard let (data, response) = try? await http.data(for: request),
                          let code = (response as? HTTPURLResponse)?.statusCode, (200...299).contains(code) else { return false }
                    return await cache.storeSegment(data, video: video, rendition: r.key, index: index)
                }
                return true
            }
            for _ in 0..<StreamCachePolicy.prefetchConnections { _ = add() }
            var count = 0
            for await ok in group {
                if !ok { failed = true }
                count += 1
                if count % 4 == 0 {
                    let (p, c) = await state(video, all)
                    await report(video, p, c)
                }
                if await proxy.activeVideoID == video || !NetworkPathObserver.shared.isAvailable {
                    group.cancelAll()
                    failed = true
                    continue
                }
                _ = add()
            }
        }
        return failed
    }

    private func state(_ video: String, _ renditions: [Rendition]) async -> (Double, Bool) {
        var done = 0, total = 0
        for r in renditions {
            done += min(await cache.cachedIndices(video: video, rendition: r.key).count, r.segments.count)
            total += r.segments.count
        }
        return (total == 0 ? 0 : Double(done) / Double(total), total > 0 && done >= total)
    }

    private func storedRenditions(_ video: String) async -> [Rendition] {
        var result: [Rendition] = []
        let audioOnly = await cache.named(video: video, name: PinnedStreamLibrary.audioOnlyMarker)
            .flatMap { String(data: $0, encoding: .utf8) } == "1"
        for kind in audioOnly ? ["rendition-audio"] : ["rendition-video", "rendition-audio"] {
            guard let key = await cache.named(video: video, name: kind).flatMap({ String(data: $0, encoding: .utf8) }),
                  let text = await cache.named(video: video, name: "pl-" + key).flatMap({ String(data: $0, encoding: .utf8) }),
                  let base = await cache.named(video: video, name: "plurl-" + key).flatMap({ String(data: $0, encoding: .utf8) }).flatMap(URL.init(string:))
            else { continue }
            result.append(Rendition(key: key, segments: HLSPlaylistText.mediaPlaylist(text, base: base).segments))
        }
        return result
    }

    /// Re-reads the same renditions from a freshly signed master.
    private func refresh(_ video: String, keys: [String], source: StreamSource) async -> [Rendition]? {
        guard let master = await text(source.master, source.headers) else { return nil }
        var urls = HLSPlaylistText.variants(in: master, base: source.master).map(\.uri)
        for line in master.components(separatedBy: .newlines) where line.hasPrefix("#EXT-X-MEDIA:") {
            if let uri = HLSPlaylistText.attributes(of: line)["URI"], let url = URL(string: uri, relativeTo: source.master) {
                urls.append(url.absoluteURL)
            }
        }
        var result: [Rendition] = []
        for key in keys {
            guard let url = urls.first(where: { HLSPlaylistText.renditionKey(for: $0) == key }),
                  let text = await text(url, source.headers) else { return nil }
            await cache.storeNamed(Data(text.utf8), video: video, name: "pl-" + key)
            await cache.storeNamed(Data(url.absoluteString.utf8), video: video, name: "plurl-" + key)
            result.append(Rendition(key: key, segments: HLSPlaylistText.mediaPlaylist(text, base: url).segments))
        }
        if let data = try? JSONEncoder().encode(source) {
            await cache.storeNamed(data, video: video, name: StreamSource.fileName)
        }
        log.notice("[pinned] \(video) URLs refreshed")
        return result
    }

    private func text(_ url: URL, _ headers: [String: String]) async -> String? {
        var request = URLRequest(url: url)
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        guard let (data, response) = try? await http.data(for: request),
              let code = (response as? HTTPURLResponse)?.statusCode, (200...299).contains(code) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
