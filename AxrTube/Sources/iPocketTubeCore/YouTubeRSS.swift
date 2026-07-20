import Foundation

// MARK: - YouTubeRSS
//
// URL construction helpers for YouTube's public Atom/RSS feeds.
// No authentication required — the same feeds any RSS reader uses.
//
// YouTube exposes a public Atom feed for every channel's uploads playlist:
//   https://www.youtube.com/feeds/videos.xml?playlist_id={uploadsPlaylistId}
//
// The uploads playlist ID is derived from the channel ID by replacing the
// "UC" prefix with "UU". A fallback URL using channel_id= is provided for
// channels whose playlist ID doesn't follow the standard UC→UU mapping.

public enum YouTubeRSS {

    // MARK: - Playlist ID derivation

    /// Converts a YouTube channel ID ("UCxxxx") to its uploads playlist ID ("UUxxxx").
    /// YouTube's RSS playlist feed uses this ID, not the channel ID directly.
    public static func uploadsPlaylistId(from channelId: String) -> String {
        guard channelId.hasPrefix("UC") else { return channelId }
        return "UU" + channelId.dropFirst(2)
    }

    // MARK: - Feed URLs

    /// Primary feed URL: uses the uploads playlist ID.
    /// Returns the last ~15 videos from the channel.
    public static func feedURL(for channelId: String) -> URL {
        let playlistId = uploadsPlaylistId(from: channelId)
        // URL is statically constructed from known-safe components — force-unwrap is intentional.
        // swiftlint:disable:next force_unwrap
        return URL(string: "https://www.youtube.com/feeds/videos.xml?playlist_id=\(playlistId)")!
    }

    /// Fallback feed URL: uses the channel ID directly.
    /// Used when the playlist variant returns 404 (e.g. handle-based or legacy channels).
    public static func fallbackFeedURL(for channelId: String) -> URL {
        // swiftlint:disable:next force_unwrap
        return URL(string: "https://www.youtube.com/feeds/videos.xml?channel_id=\(channelId)")!
    }

    // MARK: - Shorts feed URLs

    /// Converts a YouTube channel ID ("UCxxxx") to its Shorts playlist ID ("UUSHxxxx").
    /// NOTE: This is undocumented YouTube behaviour — treat as best-effort. If YouTube
    /// changes the prefix, the Shorts feed returns empty/nil and enrichment is skipped.
    public static func shortsPlaylistId(from channelId: String) -> String {
        guard channelId.hasPrefix("UC") else { return channelId }
        return "UUSH" + channelId.dropFirst(2)
    }

    /// Shorts playlist RSS feed URL for a channel.
    public static func shortsFeedURL(for channelId: String) -> URL {
        let playlistId = shortsPlaylistId(from: channelId)
        // swiftlint:disable:next force_unwrap
        return URL(string: "https://www.youtube.com/feeds/videos.xml?playlist_id=\(playlistId)")!
    }
}
