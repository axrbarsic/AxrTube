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

public enum iPocketTubeInformationArchitecture {
    public static let primaryRoutes = iPocketTubePrimaryRoute.allCases

    public static let downloadsOwner: iPocketTubeFeatureOwner = .downloads
    public static let storageOwner: iPocketTubeFeatureOwner = .downloads

    public static func showsGlobalMiniPlayer(on route: iPocketTubePrimaryRoute) -> Bool {
        route != .downloads
    }
}
