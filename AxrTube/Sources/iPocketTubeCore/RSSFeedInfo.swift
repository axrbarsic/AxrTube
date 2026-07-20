import Foundation

// MARK: - RSSFeedInfo

/// A user-added RSS feed subscription (distinct from LocalSubscriptionStore,
/// which tracks YouTube channels followed without authentication).
///
/// Codable for JSON persistence in UserDefaults.
public struct RSSFeedInfo: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public var title: String
    public let feedURL: URL
    public var isActive: Bool
    public var addedAt: Date

    public init(id: UUID = UUID(), title: String, feedURL: URL, isActive: Bool = true, addedAt: Date = Date()) {
        self.id = id
        self.title = title
        self.feedURL = feedURL
        self.isActive = isActive
        self.addedAt = addedAt
    }
}

// MARK: - YouTube RSS URL helpers

extension RSSFeedInfo {
    /// Extracts the YouTube channel ID from a YouTube RSS feed URL.
    /// Returns `nil` for non-YouTube-feed URLs.
    public static func channelId(from url: URL) -> String? {
        guard url.host == "www.youtube.com",
              url.path == "/feeds/videos.xml" else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "channel_id" })?
            .value
    }

    /// Returns `true` when the URL is a YouTube Atom/RSS feed URL.
    public static func isYouTubeRSSFeed(_ url: URL) -> Bool {
        url.host == "www.youtube.com" && url.path == "/feeds/videos.xml"
    }

    /// Builds a YouTube RSS feed URL from a channel ID.
    public static func feedURL(for channelId: String) -> URL? {
        URL(string: "https://www.youtube.com/feeds/videos.xml?channel_id=\(channelId)")
    }
}
