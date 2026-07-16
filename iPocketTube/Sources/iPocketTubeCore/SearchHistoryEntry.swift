import Foundation

// MARK: - SearchHistoryEntry
//
// A single record in the user's local search history.
// Queries are unique — re-submitting an existing query updates its timestamp
// and moves it to the top of the list rather than creating a duplicate.

public struct SearchHistoryEntry: Codable, Sendable, Identifiable, Equatable {
    /// The searched query string, used as the stable identifier.
    public var id: String { query }
    public let query: String
    /// When this query was last submitted. Used for newest-first sorting.
    public let timestamp: Date

    public init(query: String, timestamp: Date = Date()) {
        self.query = query
        self.timestamp = timestamp
    }
}
