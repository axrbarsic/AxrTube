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
