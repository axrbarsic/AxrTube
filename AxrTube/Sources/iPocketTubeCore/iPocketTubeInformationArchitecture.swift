import Foundation

/// The single source of truth for iPocketTube's four primary destinations.
public enum iPocketTubePrimaryRoute: String, CaseIterable, Sendable {
    case search
    case media
    case downloads
    case settings
}

public enum iPocketTubeFeatureOwner: String, Sendable {
    case media
    case downloads
    case settings
}

public enum iPocketTubeNowPlayingSurface: Equatable, Sendable {
    case hidden
    case compactAccessory
    case expandedDownloadsCard
}

public enum iPocketTubeInformationArchitecture {
    public static let primaryRoutes = iPocketTubePrimaryRoute.allCases

    public static let downloadsOwner: iPocketTubeFeatureOwner = .downloads
    public static let storageOwner: iPocketTubeFeatureOwner = .downloads

    public static func nowPlayingSurface(
        on route: iPocketTubePrimaryRoute,
        hasRecoverableItem: Bool
    ) -> iPocketTubeNowPlayingSurface {
        guard hasRecoverableItem else { return .hidden }
        return route == .downloads ? .expandedDownloadsCard : .compactAccessory
    }

    public static func showsGlobalMiniPlayer(
        on route: iPocketTubePrimaryRoute,
        hasRecoverableItem: Bool
    ) -> Bool {
        nowPlayingSurface(on: route, hasRecoverableItem: hasRecoverableItem) == .compactAccessory
    }
}
