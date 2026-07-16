import Foundation

/// The single source of truth for AxrTube's four primary destinations.
public enum AxrTubePrimaryRoute: String, CaseIterable, Sendable {
    case search
    case media
    case downloads
    case settings
}

public enum AxrTubeFeatureOwner: String, Sendable {
    case media
    case downloads
    case settings
}

public enum AxrTubeInformationArchitecture {
    public static let primaryRoutes = AxrTubePrimaryRoute.allCases

    public static let downloadsOwner: AxrTubeFeatureOwner = .downloads
    public static let storageOwner: AxrTubeFeatureOwner = .downloads

    public static func showsGlobalMiniPlayer(on route: AxrTubePrimaryRoute) -> Bool {
        route != .downloads
    }
}
