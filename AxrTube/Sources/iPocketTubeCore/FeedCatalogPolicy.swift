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
        let filtered = showShorts ? videos : videos.filter { !$0.isShort }
        let metadata = VideoPublicationSortPolicy.metadataByVideoID(filtered)
        var seen = Set<String>()
        return filtered.compactMap { video in
            guard !video.id.isEmpty, seen.insert(video.id).inserted else { return nil }
            guard let candidate = metadata[video.id] else { return video }
            return VideoPublicationSortPolicy.mergingPublicationMetadata(
                base: video,
                candidate: candidate
            )
        }
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
    case downloads
    case standard
}

/// Every production video-card route owned by the Media Library. Keeping this
/// list in core makes parity testable without coupling tests to SwiftUI view
/// internals. All routes resolve through the shared compact-card preference.
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
        compactCards: Bool,
        isActiveNowPlaying: Bool = false
    ) -> VideoCardLayoutVariant {
        if context == .downloads, isActiveNowPlaying {
            return .regular
        }
        return switch context {
        case .search, .mediaLibrary, .downloads:
            compactCards ? .compact : .regular
        case .standard:
            .regular
        }
    }
}

public enum VideoCardIntent: Sendable, Equatable {
    case surfaceTap
    case playback
    case download
}

public enum VideoCardPresentation: Sendable, Equatable {
    case none
    case inlinePlayer
    case player
}

public enum VideoCardCapability: Sendable, Equatable, Hashable {
    case transcript
    case menuActions
}

/// Keeps an explicit download action separate from a card's primary playback
/// action. Download progress is never allowed to become a presentation trigger.
public enum VideoCardInteractionPolicy {
    public static func presentation(for intent: VideoCardIntent) -> VideoCardPresentation {
        switch intent {
        case .surfaceTap: .none
        case .playback: .inlinePlayer
        case .download: .none
        }
    }

    public static func capabilities(whileDownloading: Bool) -> Set<VideoCardCapability> {
        [.transcript, .menuActions]
    }
}

/// Inline playback always requests durable offline storage, independent of the
/// optional full-screen auto-save setting. Completed and active entries remain
/// idempotent, so transport taps cannot create duplicate download jobs.
public enum VideoCardOfflineSavePolicy {
    public static func shouldRequestDownload(
        existingStatus: OfflineDownloadStatus?,
        downloadServiceIsActive: Bool
    ) -> Bool {
        _ = downloadServiceIsActive
        guard let existingStatus else { return true }
        return existingStatus != .completed && !existingStatus.isActive
    }
}

public enum DownloadCardStatusPresentation: Sendable, Equatable {
    case none
    case paused(showsContinue: Bool)
    case finalizationRetry
    case waitingForWiFi
    case reconnecting
    case failure(showsRetry: Bool)
    case progressAndCancel
}

/// Keeps download status controls independent from compact/regular geometry.
/// The row uses this same result in both sizes, so reducing height never hides
/// progress, error, retry, continue, or cancel actions.
public enum DownloadCardPresentationPolicy {
    public static func statusPresentation(
        status: OfflineDownloadStatus,
        resumePolicy: DownloadResumePolicy,
        failureReason: OfflineFailureReason?
    ) -> DownloadCardStatusPresentation {
        switch status {
        case .completed:
            .none
        case .paused:
            .paused(showsContinue: resumePolicy == .manual)
        case .finalizationPending:
            .finalizationRetry
        case .waitingForWiFi:
            .waitingForWiFi
        case .reconnecting:
            .reconnecting
        case .failed, .cancelled:
            .failure(showsRetry: OfflineFailurePresentationPolicy.allowsManualRetry(for: failureReason))
        case .queued, .fetching, .downloading, .saving:
            .progressAndCancel
        }
    }
}
