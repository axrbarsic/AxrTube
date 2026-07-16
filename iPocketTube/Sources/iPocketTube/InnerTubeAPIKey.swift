import SwiftUI
import iPocketTubeCore

// MARK: - InnerTubeAPIKey

private struct InnerTubeAPIKey: EnvironmentKey {
    static let defaultValue = InnerTubeAPI()
}

public extension EnvironmentValues {
    var innerTubeAPI: InnerTubeAPI {
        get { self[InnerTubeAPIKey.self] }
        set { self[InnerTubeAPIKey.self] = newValue }
    }
}
