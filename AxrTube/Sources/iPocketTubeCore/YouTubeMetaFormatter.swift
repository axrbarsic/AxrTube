import Foundation

/// Russian YouTube-style metadata for video cards:
/// "Канал · 1,2 млн просмотров · 3 дня назад".
public enum YouTubeMetaFormatter {
    public static func views(_ count: Int) -> String {
        "\(compactNumber(count)) \(viewsNoun(count))"
    }

    public static func metaLine(for video: Video, published: String?) -> String {
        var parts: [String] = []
        if !video.channelTitle.isEmpty { parts.append(video.channelTitle) }
        if let count = video.viewCount {
            parts.append(video.isLive
                ? "\(compactNumber(count)) \(plural(count, "зритель", "зрителя", "зрителей"))"
                : views(count))
        }
        if let published, !published.isEmpty, !video.isLive { parts.append(published) }
        return parts.joined(separator: " · ")
    }

    /// Abbreviated counts stay in the genitive plural, as YouTube does ("1,2 тыс. просмотров").
    private static func viewsNoun(_ count: Int) -> String {
        count >= 1_000 ? "просмотров" : plural(count, "просмотр", "просмотра", "просмотров")
    }

    private static func compactNumber(_ count: Int) -> String {
        let scales: [(Double, String)] = [(1e9, "млрд"), (1e6, "млн"), (1e3, "тыс.")]
        for (scale, suffix) in scales where Double(count) >= scale {
            let value = Double(count) / scale
            // One decimal below 10 (truncated like YouTube), whole numbers above.
            let text = value < 10
                ? String(format: "%.1f", (value * 10).rounded(.down) / 10)
                    .replacingOccurrences(of: ".0", with: "")
                    .replacingOccurrences(of: ".", with: ",")
                : String(Int(value))
            return "\(text) \(suffix)"
        }
        return String(count)
    }

    static func plural(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
        let mod10 = n % 10, mod100 = n % 100
        if mod10 == 1 && mod100 != 11 { return one }
        if (2...4).contains(mod10) && !(12...14).contains(mod100) { return few }
        return many
    }
}
