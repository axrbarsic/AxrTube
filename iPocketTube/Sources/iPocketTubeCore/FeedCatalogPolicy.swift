import Foundation

/// Shared feed contract for every iOS video catalogue. `Video.isShort` is
/// populated only from explicit InnerTube/YouTube Shorts markers; duration is
/// deliberately not consulted here, so a short regular upload remains visible.
public enum FeedCatalogPolicy {
    public static let iOSColumnCount = 1

    public static func visibleVideos(
        _ videos: [Video],
        showShorts: Bool
    ) -> [Video] {
        showShorts ? videos : videos.filter { !$0.isShort }
    }
}

/// One deterministic catalogue policy for channels returned by the authenticated
/// subscriptions endpoint. The API may repeat a channel through multiple guide
/// renderers, so deduplication and ordering happen again at the model boundary
/// instead of relying on renderer traversal order.
public enum SubscribedChannelCatalogPolicy {
    public static func sortedDeduplicated(
        _ channels: [Channel],
        locale: Locale = .current
    ) -> [Channel] {
        var channelByID: [String: Channel] = [:]

        for channel in channels where !channel.id.isEmpty {
            guard var existing = channelByID[channel.id] else {
                channelByID[channel.id] = channel
                continue
            }

            // Preserve the first record, but fill metadata that another renderer
            // supplied. This keeps the result stable while avoiding blank titles
            // or avatars when the same subscription appears twice.
            if existing.title.isEmpty, !channel.title.isEmpty { existing.title = channel.title }
            if existing.description == nil { existing.description = channel.description }
            if existing.thumbnailURL == nil { existing.thumbnailURL = channel.thumbnailURL }
            if existing.subscriberCount == nil { existing.subscriberCount = channel.subscriberCount }
            existing.isSubscribed = existing.isSubscribed || channel.isSubscribed
            channelByID[channel.id] = existing
        }

        return channelByID.values.sorted { left, right in
            if left.title.isEmpty != right.title.isEmpty { return !left.title.isEmpty }

            let localized = left.title.compare(
                right.title,
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                range: nil,
                locale: locale
            )
            if localized != .orderedSame { return localized == .orderedAscending }

            // Locale collation can consider distinct spellings equal. A literal
            // title comparison followed by the persisted channel ID makes ties
            // deterministic across renders and launches.
            if left.title != right.title { return left.title < right.title }
            return left.id < right.id
        }
    }
}

public enum VideoCardCatalogContext: Sendable, Equatable {
    case search
    case mediaLibrary
    case standard
}

/// Every production video-card route owned by the Media Library. Keeping this
/// list in core makes parity testable without coupling tests to SwiftUI view
/// internals. All of these routes must resolve through the same persisted
/// `compactMediaLibraryCards` preference.
public enum MediaLibraryVideoRoute: String, CaseIterable, Sendable {
    case subscriptions
    case history
    case playlists
    case playlistContents
    case rssFeed
    case channelUploads

    public var catalogContext: VideoCardCatalogContext { .mediaLibrary }
}

public enum VideoCardLayoutVariant: Sendable, Equatable {
    case regular
    case compact
}

/// One policy selects the existing shared card component's regular/compact
/// variant. Views do not fork their own card implementations.
public enum VideoCardLayoutPolicy {
    public static func variant(
        for context: VideoCardCatalogContext,
        compactSearchCards: Bool,
        compactMediaLibraryCards: Bool
    ) -> VideoCardLayoutVariant {
        switch context {
        case .search:
            compactSearchCards ? .compact : .regular
        case .mediaLibrary:
            compactMediaLibraryCards ? .compact : .regular
        case .standard:
            .regular
        }
    }
}
