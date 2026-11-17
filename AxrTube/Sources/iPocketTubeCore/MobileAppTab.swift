import Foundation

/// Navigation contract shared by the native shell and its parity tests.
/// Mirrors the PWA tab order without importing web runtime or account state.
public enum MobileAppTab: String, CaseIterable, Identifiable, Sendable {
    case home, shorts, subscriptions, you

    public var id: String { rawValue }

    public static func visible(hideShorts: Bool) -> [Self] {
        allCases.filter { !hideShorts || $0 != .shorts }
    }

    public func resolved(hideShorts: Bool) -> Self {
        self == .shorts && hideShorts ? .home : self
    }
}

/// Rows of the YouTube "Вы" tab. History and playlists are shelves above the
/// rows (signed in); settings live behind the gear in the top bar.
public enum MobileProfileDestination: String, Hashable, Sendable {
    case channels, playlists, history, watchLater, liked, queue, downloads, settings

    public static func accountEntries(signedIn: Bool) -> [Self] {
        signedIn ? [.liked, .channels] : [.channels]
    }

    public static let deviceEntries: [Self] = [.downloads, .queue]
}
