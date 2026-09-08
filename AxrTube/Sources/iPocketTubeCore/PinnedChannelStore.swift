import Foundation
import Observation

/// Local bookmarks, independent of the current YouTube subscriptions response.
@MainActor @Observable
public final class PinnedChannelStore {
    public static let shared = PinnedChannelStore()
    public private(set) var channels: [Channel]
    private let defaults: UserDefaults
    private static let key = "axrtube.pinnedChannels.v1"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        channels = defaults.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode([Channel].self, from: $0) } ?? []
    }

    public func contains(_ id: String) -> Bool { channels.contains { $0.id == id } }

    public func toggle(_ channel: Channel) {
        guard !channel.id.isEmpty else { return }
        if contains(channel.id) { channels.removeAll { $0.id == channel.id } }
        else { channels.append(channel) }
        if let data = try? JSONEncoder().encode(channels) {
            defaults.set(data, forKey: Self.key)
        }
    }

    public func orderedChannels(_ fetched: [Channel]) -> [Channel] {
        let fresh = SubscribedChannelCatalogPolicy.sortedDeduplicated(fetched)
        let pinned = channels.map { saved in fresh.first { $0.id == saved.id } ?? saved }
        return pinned + fresh.filter { !contains($0.id) }
    }
}
