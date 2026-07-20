import Foundation

// MARK: - RSSParseResult

public struct RSSParseResult: Sendable {
    /// Channel display name extracted from the feed's <author><name> element.
    public let channelName: String?
    /// Videos extracted from <entry> elements, in feed order (newest first).
    public let videos: [Video]
}

// MARK: - parseYouTubeRSS

/// Parses YouTube's public Atom/RSS feed into Video objects.
///
/// Uses Foundation's `XMLParser` (SAX) — available on iOS, tvOS, and macOS.
/// Tolerates partial results: returns whatever was successfully parsed before
/// any error rather than throwing.
///
/// Fields extracted per `<entry>`:
///   - `<yt:videoId>` → `Video.id`
///   - `<title>`      → `Video.title`
///   - `<published>`  → `Video.publishedAt`
///   - `<media:thumbnail url="">` → `Video.thumbnailURL`
///   - `<media:statistics views="">` → `Video.viewCount`
///   - `<author><name>` → `Video.channelTitle`
///
/// Fields not present in RSS (left nil/default):
///   - `duration` / `lengthSeconds` — not available; left nil
///   - `isShort` — not detectable; left false
public func parseYouTubeRSS(_ data: Data, channelId: String) -> RSSParseResult {
    let delegate = RSSParserDelegate(channelId: channelId)
    let parser = XMLParser(data: data)
    parser.delegate = delegate
    parser.parse()
    return RSSParseResult(channelName: delegate.channelName, videos: delegate.videos)
}

// MARK: - RSSParserDelegate

private final class RSSParserDelegate: NSObject, XMLParserDelegate, @unchecked Sendable {

    let channelId: String
    private(set) var channelName: String?
    private(set) var videos: [Video] = []

    // Per-entry accumulator
    private var inEntry = false
    private var inAuthor = false
    private var currentText = ""

    private var currentVideoId: String?
    private var currentTitle: String?
    private var currentPublished: Date?
    private var currentViewCount: Int?
    private var currentThumbnailURL: URL?
    private var currentAuthor: String?

    // ISO 8601 formatter — YouTube uses "2024-01-15T18:00:00+00:00" format.
    // Instantiated per-parser-run (not a static) to avoid shared mutable state
    // across concurrent parses under Swift 6 strict concurrency.
    private let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    init(channelId: String) {
        self.channelId = channelId
    }

    // MARK: - XMLParserDelegate

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes: [String: String] = [:]
    ) {
        currentText = ""

        switch elementName {
        case "entry":
            inEntry = true
            currentVideoId = nil
            currentTitle = nil
            currentPublished = nil
            currentViewCount = nil
            currentThumbnailURL = nil
            currentAuthor = nil

        case "author":
            inAuthor = true

        case "media:thumbnail":
            if let urlString = attributes["url"], let url = URL(string: urlString) {
                currentThumbnailURL = url
            }

        case "media:statistics":
            if let viewsStr = attributes["views"], let count = Int(viewsStr) {
                currentViewCount = count
            }

        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?
    ) {
        let trimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)

        switch elementName {
        case "yt:videoId":
            if inEntry { currentVideoId = trimmed }

        case "title":
            if inEntry { currentTitle = trimmed }

        case "published":
            if inEntry { currentPublished = isoFormatter.date(from: trimmed) }

        case "name":
            if inAuthor {
                if inEntry {
                    currentAuthor = trimmed
                } else {
                    // Feed-level <author><name> = channel name
                    channelName = trimmed
                }
            }

        case "author":
            inAuthor = false

        case "entry":
            if let videoId = currentVideoId, !videoId.isEmpty {
                let video = Video(
                    id: videoId,
                    title: currentTitle ?? "",
                    channelTitle: currentAuthor ?? channelName ?? "",
                    channelId: channelId,
                    thumbnailURL: currentThumbnailURL,
                    viewCount: currentViewCount,
                    publishedAt: currentPublished
                )
                videos.append(video)
            }
            inEntry = false

        default:
            break
        }

        currentText = ""
    }
}
