public enum AudioFirstPresentationDestination: Equatable, Sendable {
    case miniPlayer
}

/// Product-level tap policy kept pure so every card type can be regression-tested
/// without constructing a player or issuing a network request.
public enum AudioFirstPresentationPolicy {
    public static func destination(for video: Video) -> AudioFirstPresentationDestination {
        .miniPlayer
    }
}
