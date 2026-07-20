import Foundation

// MARK: - LocalChannel
//
// Minimal representation of a locally followed channel.
// No authentication required — just { id, title, thumbnailURL }.
// Stored by LocalSubscriptionStore as JSON in UserDefaults.
//
// Only three fields are kept: a channel subscription is just a record of intent.
// Metadata (title, thumbnail) is refreshed from RSS on each feed fetch.

public struct LocalChannel: Codable, Hashable, Sendable, Identifiable {
    public let id: String           // YouTube channel ID, e.g. "UCBcRF18a7Qf58cCRy5xuWwQ"
    public var title: String
    public var thumbnailURL: URL?
    public var addedAt: Date

    public init(id: String, title: String, thumbnailURL: URL? = nil) {
        self.id = id
        self.title = title
        self.thumbnailURL = thumbnailURL
        self.addedAt = Date()
    }
}

// MARK: - Channel conversion

extension LocalChannel {
    /// Converts to the shared Channel model used across views and BrowseViewModel.
    public func toChannel() -> Channel {
        Channel(id: id, title: title, thumbnailURL: thumbnailURL, isSubscribed: true)
    }
}
