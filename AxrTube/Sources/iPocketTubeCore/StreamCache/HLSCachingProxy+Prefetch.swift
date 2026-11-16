import Foundation

// MARK: - Up-next head prefetch
//
// Downloads the first `seconds` of another video into the cache the same
// way a session would (same variant choice, same rendition keys), so when it
// starts the proxy serves those segments from disk at once.
extension HLSCachingProxy {
    public func prefetchHead(
        videoID: String, masterURL: URL, headers: [String: String],
        preferredMaxHeight: Int?, seconds: Double = 60
    ) async {
        guard session?.video != videoID, NetworkPathObserver.shared.isAvailable,
              let (masterData, _) = try? await fetch(masterURL, headers: headers),
              let master = String(data: masterData, encoding: .utf8) else { return }
        let budget = estimate.variantBudget(parallelConnections: StreamCachePolicy.prefetchConnections)
        let maxHeight = preferredMaxHeight
            ?? (budget == nil ? StreamCachePolicy.unknownNetworkMaxHeight : StreamCachePolicy.autoMaxHeight)
        guard let chosen = HLSPlaylistText.selectVariant(
            HLSPlaylistText.variants(in: master, base: masterURL), maxHeight: maxHeight, bandwidthBudget: budget
        ) else { return }
        if let source = try? JSONEncoder().encode(StreamSource(master: masterURL, headers: headers)) {
            await cache.storeNamed(source, video: videoID, name: StreamSource.fileName)
        }
        await cache.storeNamed(masterData, video: videoID, name: "master")
        let videoKey = HLSPlaylistText.renditionKey(for: chosen.uri)
        await cache.storeNamed(Data(videoKey.utf8), video: videoID, name: "variant")

        var renditions: [(url: URL, isAudio: Bool)] = [(chosen.uri, false)]
        if let audio = Self.audioRendition(in: master, base: masterURL, group: chosen.audioGroup) {
            renditions.append((audio, true))
        }
        for rendition in renditions {
            guard session?.video != videoID else { return }  // it started playing: the session owns it
            let key = HLSPlaylistText.renditionKey(for: rendition.url)
            guard let (data, _) = try? await fetch(rendition.url, headers: headers),
                  let text = String(data: data, encoding: .utf8) else { continue }
            await cache.storeNamed(data, video: videoID, name: "pl-" + key)
            await cache.storeNamed(Data(rendition.url.absoluteString.utf8), video: videoID, name: "plurl-" + key)
            await cache.storeNamed(Data(key.utf8), video: videoID, name: rendition.isAudio ? "rendition-audio" : "rendition-video")
            let info = HLSPlaylistText.mediaPlaylist(text, base: rendition.url)
            var start = 0.0
            for (index, url) in info.segments.enumerated() {
                defer { start += index < info.segmentDurations.count ? info.segmentDurations[index] : 0 }
                guard start < seconds, !Task.isCancelled, session?.video != videoID,
                      NetworkPathObserver.shared.isAvailable else { break }
                if await cache.hasSegment(video: videoID, rendition: key, index: index) { continue }
                guard let (segment, _) = try? await fetch(url, headers: headers) else { break }
                await cache.storeSegment(segment, video: videoID, rendition: key, index: index)
            }
        }
        log.notice("[stream-cache] prefetched first \(Int(seconds))s of \(videoID)")
    }

    /// Default audio rendition of the variant's audio group.
    static func audioRendition(in master: String, base: URL, group: String?) -> URL? {
        guard let group else { return nil }
        var fallback: URL?
        for line in master.components(separatedBy: .newlines) where line.hasPrefix("#EXT-X-MEDIA:") {
            let a = HLSPlaylistText.attributes(of: line)
            guard a["TYPE"] == "AUDIO", a["GROUP-ID"] == group, let uri = a["URI"],
                  let url = URL(string: uri, relativeTo: base)?.absoluteURL else { continue }
            if a["DEFAULT"] == "YES" { return url }
            fallback = fallback ?? url
        }
        return fallback
    }
}
