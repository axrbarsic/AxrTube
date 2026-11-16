import Foundation

// MARK: - Request routing
//
//   /<session>/master.m3u8        single-variant master
//   /<session>/pl/<id>.m3u8       media playlist (video or audio rendition)
//   /<session>/seg/<id>/<n>       segment n of playlist id
//   /<session>/x/<id>             other resource (init map, key)
extension HLSCachingProxy {
    static let playlistMime = "application/vnd.apple.mpegurl"

    func handle(_ request: LoopbackHTTPServer.Request) async -> LoopbackHTTPServer.Response {
        let parts = request.path.split(separator: "?").first.map { $0.split(separator: "/").map(String.init) } ?? []
        guard parts.count >= 2, let s = session, parts[0] == s.id else { return .init(status: 404) }
        switch parts[1] {
        case "master.m3u8":
            return await master(session: s.id)
        case "pl" where parts.count == 3:
            guard let pid = Int(parts[2].replacingOccurrences(of: ".m3u8", with: "")) else { break }
            return await mediaPlaylist(session: s.id, playlist: pid)
        case "seg" where parts.count == 4:
            guard let pid = Int(parts[2]), let index = Int(parts[3]) else { break }
            session?.playlists[pid]?.cursor = index
            session?.playlists[pid]?.touched = Date()
            guard let (data, mime) = await loadSegment(session: s.id, playlist: pid, index: index) else {
                return .init(status: 502)
            }
            return .init(status: 200, contentType: mime, body: data)
        case "x" where parts.count == 3:
            guard let oid = Int(parts[2]) else { break }
            return await other(session: s.id, id: oid)
        default:
            break
        }
        return .init(status: 404)
    }

    // MARK: Master

    private func master(session id: String) async -> LoopbackHTTPServer.Response {
        guard let s = session, s.id == id else { return .init(status: 404) }
        let online = try? await fetch(s.master, headers: s.headers)
        let text: String
        if let (data, _) = online, let fresh = String(data: data, encoding: .utf8) {
            text = fresh
            await cache.storeNamed(data, video: s.video, name: "master")
        } else if let data = await cache.named(video: s.video, name: "master"),
                  let stored = String(data: data, encoding: .utf8) {
            text = stored
            log.notice("[stream-cache] master served from disk (offline)")
        } else {
            return .init(status: 502)
        }
        guard session?.id == id else { return .init(status: 404) }
        let all = HLSPlaylistText.variants(in: text, base: s.master)
        let budget = estimate.variantBudget(parallelConnections: StreamCachePolicy.prefetchConnections)
        // Offline: stay on the variant downloaded last time.
        let previous = await cache.named(video: s.video, name: "variant").flatMap { String(data: $0, encoding: .utf8) }
        let reused = online == nil ? all.first { HLSPlaylistText.renditionKey(for: $0.uri) == previous } : nil
        guard let chosen = reused ?? HLSPlaylistText.selectVariant(all, maxHeight: s.maxHeight, bandwidthBudget: budget) else {
            return .init(status: 502)
        }
        let chosenKey = HLSPlaylistText.renditionKey(for: chosen.uri)
        await cache.storeNamed(Data(chosenKey.utf8), video: s.video, name: "variant")
        log.notice("[stream-cache] variant \(chosen.height)p bw=\(chosen.bandwidth) of \(all.count)")
        var rewritten = ""
        rewritten = HLSPlaylistText.rewriteMaster(text, base: s.master, keep: chosen) { url in
            "/\(id)/pl/\(self.registerPlaylist(url)).m3u8"
        }
        return .init(status: 200, contentType: Self.playlistMime, body: Data(rewritten.utf8))
    }

    private func registerPlaylist(_ url: URL) -> Int {
        let rendition = HLSPlaylistText.renditionKey(for: url)
        if let existing = session?.playlists.first(where: { $0.value.rendition == rendition })?.key {
            session?.playlists[existing]?.origin = url
            return existing
        }
        let pid = (session?.playlists.keys.max() ?? 0) + 1
        session?.playlists[pid] = Playlist(origin: url, rendition: rendition)
        return pid
    }

    // MARK: Media playlists

    private func mediaPlaylist(session id: String, playlist pid: Int) async -> LoopbackHTTPServer.Response {
        guard let s = session, s.id == id, let pl = s.playlists[pid] else { return .init(status: 404) }
        let name = "pl-" + pl.rendition
        let text: String
        if let (data, _) = try? await fetch(pl.origin, headers: s.headers),
           let fresh = String(data: data, encoding: .utf8) {
            text = fresh
            await cache.storeNamed(data, video: s.video, name: name)
        } else if let data = await cache.named(video: s.video, name: name),
                  let stored = String(data: data, encoding: .utf8) {
            text = stored
        } else {
            return .init(status: 502)
        }
        let info = HLSPlaylistText.mediaPlaylist(text, base: pl.origin)
        let done = await cache.cachedIndices(video: s.video, rendition: pl.rendition)
        guard session?.id == id else { return .init(status: 404) }
        var starts: [Double] = []
        var t = 0.0
        for d in info.segmentDurations { starts.append(t); t += d }
        session?.playlists[pid]?.segments = info.segments
        session?.playlists[pid]?.starts = starts
        session?.playlists[pid]?.done = done
        if let mime = await cache.named(video: s.video, name: "mime-" + pl.rendition).flatMap({ String(data: $0, encoding: .utf8) }) {
            session?.playlists[pid]?.mime = mime
        }
        session?.playlists[pid]?.touched = Date()
        if !info.isComplete {
            // Live/sliding playlists are not cached ahead.
            session?.playlists[pid]?.touched = .distantPast
        }
        let rewritten = HLSPlaylistText.rewriteMedia(
            text, base: pl.origin,
            segmentURI: { "/\(id)/seg/\(pid)/\($0)" },
            rewrite: { url in "/\(id)/x/\(self.registerOther(url, rendition: pl.rendition))" }
        )
        log.notice("[stream-cache] playlist \(pl.rendition): \(info.segments.count) segments, \(done.count) on disk")
        return .init(status: 200, contentType: Self.playlistMime, body: Data(rewritten.utf8))
    }

    private func registerOther(_ url: URL, rendition: String) -> Int {
        let oid = (session?.others.keys.max() ?? 0) + 1
        session?.others[oid] = (url, "x-\(rendition)-\(HLSPlaylistText.renditionKey(for: url))")
        return oid
    }

    private func other(session id: String, id oid: Int) async -> LoopbackHTTPServer.Response {
        guard let s = session, s.id == id, let entry = s.others[oid] else { return .init(status: 404) }
        if let data = await cache.named(video: s.video, name: entry.name) {
            return .init(status: 200, body: data)
        }
        guard let (data, mime) = try? await fetch(entry.url, headers: s.headers) else { return .init(status: 502) }
        await cache.storeNamed(data, video: s.video, name: entry.name)
        return .init(status: 200, contentType: mime, body: data)
    }
}
