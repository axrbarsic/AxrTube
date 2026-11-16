import Foundation

/// One `#EXT-X-STREAM-INF` entry of a master playlist.
public struct HLSVariantEntry: Equatable, Sendable {
    public var infLine: String
    public var uri: URL
    public var bandwidth: Int
    public var height: Int
    public var audioGroup: String?
    /// YouTube marks dubbed-language variants with `YT-EXT-AUDIO-CONTENT-ID`.
    public var audioContentID: String?
    public var codecs: String
}

/// A parsed media playlist (segments of one rendition).
public struct HLSMediaPlaylistInfo: Equatable, Sendable {
    public var segments: [URL]
    public var segmentDurations: [Double]
    public var mapURL: URL?
    public var isComplete: Bool
}

/// Text-level HLS helpers for the caching proxy: parse, pick one variant,
/// and rewrite every URI so the player fetches through the proxy.
public enum HLSPlaylistText {

    // MARK: Attributes

    /// Parses `KEY=VALUE,KEY="quoted, value"` attribute lists.
    public static func attributes(of line: String) -> [String: String] {
        guard let colon = line.firstIndex(of: ":") else { return [:] }
        var result: [String: String] = [:]
        var key = "", value = "", readingKey = true, quoted = false
        func flush() {
            let k = key.trimmingCharacters(in: .whitespaces)
            if !k.isEmpty { result[k] = value }
            key = ""; value = ""; readingKey = true
        }
        for ch in line[line.index(after: colon)...] {
            if readingKey {
                if ch == "=" { readingKey = false } else if ch != "," { key.append(ch) }
            } else if ch == "\"" {
                quoted.toggle()
            } else if ch == ",", !quoted {
                flush()
            } else {
                value.append(ch)
            }
        }
        flush()
        return result
    }

    private static func resolve(_ uri: String, base: URL) -> URL? {
        URL(string: uri.trimmingCharacters(in: .whitespaces), relativeTo: base)?.absoluteURL
    }

    // MARK: Master

    public static func isMaster(_ text: String) -> Bool {
        text.contains("#EXT-X-STREAM-INF")
    }

    public static func variants(in text: String, base: URL) -> [HLSVariantEntry] {
        var result: [HLSVariantEntry] = []
        var pending: String?
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#EXT-X-STREAM-INF:") {
                pending = line
            } else if let inf = pending, !line.isEmpty, !line.hasPrefix("#") {
                pending = nil
                guard let url = resolve(line, base: base) else { continue }
                let a = attributes(of: inf)
                let height = a["RESOLUTION"]?.split(separator: "x").last.flatMap { Int($0) } ?? 0
                result.append(HLSVariantEntry(
                    infLine: inf, uri: url,
                    bandwidth: Int(a["BANDWIDTH"] ?? "") ?? 0,
                    height: height,
                    audioGroup: a["AUDIO"],
                    audioContentID: a["YT-EXT-AUDIO-CONTENT-ID"],
                    codecs: a["CODECS"] ?? ""
                ))
            }
        }
        return result
    }

    /// Picks the one variant the proxy exposes. Original-language variants
    /// win over dubbed ones; then the best height within `maxHeight` whose
    /// bandwidth fits `bandwidthBudget`; H.264 breaks ties. Falls back to the
    /// lightest variant when nothing fits the budget.
    public static func selectVariant(
        _ all: [HLSVariantEntry], maxHeight: Int, bandwidthBudget: Int?
    ) -> HLSVariantEntry? {
        let original = all.filter { $0.audioContentID == nil }
        let pool = original.isEmpty ? all : original
        guard !pool.isEmpty else { return nil }
        let withinHeight = pool.filter { $0.height == 0 || $0.height <= maxHeight }
        let candidates = withinHeight.isEmpty ? pool : withinHeight
        let fitting = candidates.filter { bandwidthBudget == nil || $0.bandwidth <= bandwidthBudget! }
        func rank(_ v: HLSVariantEntry) -> (Int, Int, Int) {
            (v.height, v.codecs.contains("avc1") ? 1 : 0, -v.bandwidth)
        }
        if let best = fitting.max(by: { rank($0) < rank($1) }) { return best }
        return candidates.min { ($0.bandwidth, $0.height) < ($1.bandwidth, $1.height) }
    }

    /// Master with only `keep` as the stream variant; `#EXT-X-MEDIA` URIs and
    /// the variant URI are replaced through `rewrite`.
    public static func rewriteMaster(
        _ text: String, base: URL, keep: HLSVariantEntry, rewrite: (URL) -> String
    ) -> String {
        var out: [String] = []
        var pendingKeep: Bool?
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#EXT-X-STREAM-INF:") {
                pendingKeep = line == keep.infLine
                if pendingKeep == true { out.append(line) }
            } else if let keepIt = pendingKeep, !line.isEmpty, !line.hasPrefix("#") {
                if keepIt { out.append(rewrite(keep.uri)) }
                pendingKeep = nil
            } else if line.hasPrefix("#EXT-X-I-FRAME-STREAM-INF") {
                continue
            } else if line.hasPrefix("#EXT-X-MEDIA:") {
                out.append(rewriteURIAttribute(line, base: base, rewrite: rewrite))
            } else {
                out.append(line)
            }
        }
        return out.joined(separator: "\n")
    }

    // MARK: Media

    public static func mediaPlaylist(_ text: String, base: URL) -> HLSMediaPlaylistInfo {
        var segments: [URL] = [], durations: [Double] = []
        var mapURL: URL?
        var duration = 0.0
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#EXTINF:") {
                duration = Double(line.dropFirst(8).split(separator: ",").first ?? "") ?? 0
            } else if line.hasPrefix("#EXT-X-MAP:") {
                mapURL = attributes(of: line)["URI"].flatMap { resolve($0, base: base) }
            } else if !line.isEmpty, !line.hasPrefix("#"), let url = resolve(line, base: base) {
                segments.append(url)
                durations.append(duration)
                duration = 0
            }
        }
        return HLSMediaPlaylistInfo(
            segments: segments, segmentDurations: durations, mapURL: mapURL,
            isComplete: text.contains("#EXT-X-ENDLIST")
        )
    }

    /// Replaces segment lines by `segmentURI(index)` and other URIs (map,
    /// keys) through `rewrite`.
    public static func rewriteMedia(
        _ text: String, base: URL, segmentURI: (Int) -> String, rewrite: (URL) -> String
    ) -> String {
        var out: [String] = []
        var index = 0
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#EXT-X-MAP:") || line.hasPrefix("#EXT-X-KEY:") {
                out.append(rewriteURIAttribute(line, base: base, rewrite: rewrite))
            } else if !line.isEmpty, !line.hasPrefix("#") {
                out.append(segmentURI(index))
                index += 1
            } else {
                out.append(line)
            }
        }
        return out.joined(separator: "\n")
    }

    private static func rewriteURIAttribute(_ line: String, base: URL, rewrite: (URL) -> String) -> String {
        guard let start = line.range(of: "URI=\"") else { return line }
        guard let end = line[start.upperBound...].firstIndex(of: "\"") else { return line }
        let uri = String(line[start.upperBound..<end])
        guard let url = resolve(uri, base: base) else { return line }
        return line.replacingCharacters(in: start.upperBound..<end, with: rewrite(url))
    }

    /// Stable key of a rendition across sessions (signed URLs change):
    /// YouTube puts `/itag/NNN/` in the path; otherwise a hash of the path.
    public static func renditionKey(for url: URL) -> String {
        let parts = url.path.split(separator: "/")
        if let i = parts.firstIndex(of: "itag"), i + 1 < parts.count { return "itag\(parts[i + 1])" }
        var hash: UInt64 = 1469598103934665603
        for byte in url.path.utf8 { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        return "p" + String(hash, radix: 36)
    }
}
