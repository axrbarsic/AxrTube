import Foundation

extension InnerTubeAPI {
    /// Channels YouTube places at the top of mixed search results.
    public func searchChannels(query: String, limit: Int = 3) async throws -> [Channel] {
        var body = makeBody(client: webClientContext)
        body["query"] = query
        let data = try await post(endpoint: "search", body: body)
        return Array(SearchChannelParser.channels(in: data, text: { self.extractText($0) }).prefix(limit))
    }
}

/// Reads `channelRenderer` items from a WEB search response.
enum SearchChannelParser {
    static func channels(in json: [String: Any], text: ([String: Any]) -> String?) -> [Channel] {
        var result: [Channel] = []
        var seen = Set<String>()

        func walk(_ object: Any, depth: Int) {
            guard depth < 40 else { return }
            if let array = object as? [Any] {
                array.forEach { walk($0, depth: depth + 1) }
                return
            }
            guard let dict = object as? [String: Any] else { return }
            if let renderer = dict["channelRenderer"] as? [String: Any],
               let id = renderer["channelId"] as? String, !id.isEmpty, seen.insert(id).inserted {
                let thumbs = (renderer["thumbnail"] as? [String: Any])?["thumbnails"] as? [[String: Any]]
                let avatar = (thumbs?.last?["url"] as? String).flatMap { URL(string: $0.hasPrefix("//") ? "https:" + $0 : $0) }
                // YouTube now puts the @handle in subscriberCountText and the
                // subscriber count in videoCountText; show whichever reads as a count.
                let handle = (renderer["subscriberCountText"] as? [String: Any]).flatMap(text)
                let count = (renderer["videoCountText"] as? [String: Any]).flatMap(text)
                let meta = [handle, count].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " • ")
                result.append(Channel(
                    id: id,
                    title: (renderer["title"] as? [String: Any]).flatMap(text) ?? "",
                    thumbnailURL: avatar,
                    subscriberCount: meta.isEmpty ? nil : meta
                ))
                return
            }
            for value in dict.values { walk(value, depth: depth + 1) }
        }

        walk(json["contents"] ?? json, depth: 0)
        return result
    }
}
