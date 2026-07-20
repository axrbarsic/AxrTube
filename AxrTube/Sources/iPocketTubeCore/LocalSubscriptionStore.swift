import Foundation

// MARK: - LocalSubscriptionStore
//
// Persists locally followed channels on-device in UserDefaults as JSON.
// No authentication required — mirrors the VideoStateStore pattern exactly.
// Thread-safe: implemented as a Swift actor.
//
// Subscriptions are stored as a [channelId: LocalChannel] dictionary.
// On each RSS refresh, metadata (title, thumbnail) is updated via updateMetadata().

public actor LocalSubscriptionStore: UserDefaultsBackedStore {

    // MARK: - Singleton

    public static let shared = LocalSubscriptionStore()

    // MARK: - Storage key

    static let defaultsKey = "st_local_subscriptions"

    // MARK: - State

    private var channels: [String: LocalChannel] = [:]
    let defaults: UserDefaults

    // MARK: - Init

    private init() {
        self.defaults = .standard
        if let loaded = Self.loadFrom(.standard) { channels = loaded }
    }

    /// Designated initializer for unit testing.
    /// Pass a unique `suiteName` string to get a fully isolated store with no
    /// shared UserDefaults state — mirrors VideoStateStore(suiteName:).
    init(suiteName: String) {
        self.defaults = UserDefaults(suiteName: suiteName) ?? .standard
        if let loaded = Self.loadFrom(self.defaults) { channels = loaded }
    }

    // MARK: - Public API

    /// Returns true if the channel with `channelId` is currently followed.
    public func isFollowing(_ channelId: String) -> Bool {
        channels[channelId] != nil
    }

    /// Returns all followed channels sorted alphabetically by title.
    public func allChannels() -> [LocalChannel] {
        channels.values.sorted {
            $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }

    /// Returns all followed channels sorted by subscription date, newest-first.
    public func allChannelsSortedBySubscriptionDate() -> [LocalChannel] {
        channels.values.sorted { $0.addedAt > $1.addedAt }
    }

    /// Follows a channel. Idempotent — following the same ID again is a no-op.
    public func follow(_ channel: LocalChannel) {
        guard channels[channel.id] == nil else { return }
        channels[channel.id] = channel
        persist()
    }

    /// Unfollows a channel by ID. No-op if the channel is not currently followed.
    public func unfollow(channelId: String) {
        channels.removeValue(forKey: channelId)
        persist()
    }

    /// Updates the stored name and/or thumbnail for an already-followed channel.
    /// Called after an RSS refresh to keep metadata fresh without a separate API call.
    /// No-op if the channel is not currently followed.
    public func updateMetadata(channelId: String, title: String?, thumbnailURL: URL?) {
        guard channels[channelId] != nil else { return }
        if let title, !title.isEmpty {
            channels[channelId]?.title = title
        }
        if let thumbnailURL {
            channels[channelId]?.thumbnailURL = thumbnailURL
        }
        persist()
    }

    // MARK: - UserDefaultsBackedStore

    func encodedValue() -> [String: LocalChannel] { channels }
    func decodeValue(_ decoded: [String: LocalChannel]) { channels = decoded }

    func afterPersist() {
        let value = channels
        Task { await iCloudSyncManager.shared.push(.subscriptions, value) }
    }
}
