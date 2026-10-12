import Foundation

/// Pure helpers for saving YouTube's HLS audio rendition as an offline file.
/// YouTube serves audio renditions as packed AAC segments (ID3 + ADTS); the
/// segments concatenate into one ADTS stream once the ID3 tags are removed.
public enum HLSAudioExtraction {
    /// The audio rendition used by the highest-bandwidth variant (best quality).
    public static func bestAudioPlaylistURL(masterText: String, masterURL: URL) -> URL? {
        let lines = masterText.split(whereSeparator: \.isNewline).map(String.init)
        var audioByGroup: [String: URL] = [:]
        for line in lines where line.hasPrefix("#EXT-X-MEDIA:") && line.contains("TYPE=AUDIO") {
            guard let group = attribute("GROUP-ID", in: line),
                  let uri = attribute("URI", in: line),
                  let url = URL(string: uri, relativeTo: masterURL)?.absoluteURL else { continue }
            audioByGroup[group] = url
        }
        guard !audioByGroup.isEmpty else { return nil }
        let best = lines
            .filter { $0.hasPrefix("#EXT-X-STREAM-INF:") }
            .compactMap { line -> (Int, String)? in
                guard let group = attribute("AUDIO", in: line),
                      let bandwidth = attribute("BANDWIDTH", in: line).flatMap(Int.init) else { return nil }
                return (bandwidth, group)
            }
            .max { $0.0 < $1.0 }
        if let best, let url = audioByGroup[best.1] { return url }
        return audioByGroup.values.first
    }

    public static func segmentURLs(playlistText: String, playlistURL: URL) -> [URL] {
        playlistText
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            .compactMap { URL(string: $0, relativeTo: playlistURL)?.absoluteURL }
    }

    /// Removes a leading ID3v2 tag (HLS packed-audio timestamp) if present.
    public static func stripID3(_ data: Data) -> Data {
        let bytes = [UInt8](data.prefix(10))
        guard bytes.count == 10, bytes[0] == 0x49, bytes[1] == 0x44, bytes[2] == 0x33 else { return data }
        // Syncsafe integer: 7 significant bits per byte.
        let size = bytes[6...9].reduce(0) { ($0 << 7) | Int($1 & 0x7F) }
        let footer = (bytes[5] & 0x10) != 0 ? 10 : 0
        let total = 10 + size + footer
        guard total <= data.count else { return data }
        return data.subdata(in: data.startIndex + total ..< data.endIndex)
    }

    private static func attribute(_ name: String, in line: String) -> String? {
        guard let range = line.range(of: name + "=") else { return nil }
        let rest = line[range.upperBound...]
        if rest.hasPrefix("\"") {
            let body = rest.dropFirst()
            return body.firstIndex(of: "\"").map { String(body[..<$0]) }
        }
        return String(rest.prefix { $0 != "," })
    }
}
