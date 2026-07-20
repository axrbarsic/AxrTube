import Foundation
import os

private let syncLog = Logger(subsystem: appSubsystem, category: "iCloudSync")

// MARK: - iCloudSyncManager
//
// Manages bidirectional sync of actor-based stores to NSUbiquitousKeyValueStore.
// Stores call push(_:_:) after every persist() mutation when sync is enabled.
// The manager fires externalChanges events when another device writes to a key
// so the app layer can reload the affected store.
//
// Task #98: opt-in sync toggle. syncEnabled is set by the app layer (SettingsStore)
// and defaults to false. All iCloud KV keys are prefixed with "smarttube_" to
// avoid collisions with other apps sharing the same container.

// MARK: - SyncableStore keys

public enum SyncableStore: String, Sendable {
    case subscriptions = "smarttube_subscriptions"
    case rssFeeds      = "smarttube_rss_feeds"
    case videoState    = "smarttube_video_state"
    case currentQueue  = "smarttube_current_queue"
}

// MARK: - iCloudSyncManager

public actor iCloudSyncManager {

    // MARK: - Singleton

    public static let shared = iCloudSyncManager()

    // MARK: - Sync toggle

    /// Set to `true` by the app layer when `AppSettings.iCloudSyncEnabled` becomes `true`.
    /// `nonisolated(unsafe)` because it is written on @MainActor (SettingsStore) and read
    /// from this actor — the worst-case data race is one extra or missed push, which is harmless.
    public nonisolated(unsafe) var syncEnabled: Bool = false

    // MARK: - Storage

    private let kvStore = NSUbiquitousKeyValueStore.default

    // MARK: - External change stream

    private let (externalChanges, externalChangesContinuation) =
        AsyncStream<SyncableStore>.makeStream()

    /// Stream of stores that received an external update from another device.
    /// Observe this stream to reload a store's in-memory state from iCloud.
    public nonisolated var changes: AsyncStream<SyncableStore> { externalChanges }

    // MARK: - Lifecycle

    private init() {}

    /// Begin listening for external iCloud KV changes. Call once on app launch.
    /// Calling `synchronize()` pulls the latest values from the server.
    /// When no iCloud account is signed in the synchronize call would silently fail
    /// with SyncedDefaults Code=8888 "No account" — guard against this so the error
    /// does not pollute device logs.
    public func start() {
        guard FileManager.default.ubiquityIdentityToken != nil else {
            // No iCloud account on this device — register for identity changes so we
            // can start syncing if the user signs in while the app is running.
            NotificationCenter.default.addObserver(
                forName: NSNotification.Name.NSUbiquityIdentityDidChange,
                object: nil,
                queue: nil
            ) { [weak self] _ in
                Task { await self?.handleIdentityChange() }
            }
            return
        }
        startSync()
    }

    // MARK: - Push

    /// Encodes `value` as JSON and pushes it to the iCloud KV store.
    /// No-op when `syncEnabled` is `false`.
    public func push<T: Codable & Sendable>(_ store: SyncableStore, _ value: T) {
        guard syncEnabled else { return }
        do {
            let data = try JSONEncoder().encode(value)
            kvStore.set(data, forKey: store.rawValue)
        } catch {
            syncLog.error("[\(store.rawValue, privacy: .public)] push failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Pull

    /// Reads and JSON-decodes a value from the iCloud KV store.
    /// Returns `nil` when the key is absent or decoding fails.
    public func pull<T: Codable & Sendable>(_ store: SyncableStore, as type: T.Type) -> T? {
        guard let data = kvStore.data(forKey: store.rawValue) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    // MARK: - Private

    private func startSync() {
        kvStore.synchronize()
        // Use the callback-based observer so the non-Sendable Notification.userInfo
        // is consumed synchronously (before any actor crossing). Only the extracted
        // [String] — a Sendable type — crosses into the actor via the Task.
        NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            let changedKeys = (notification.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey]
                as? [String]) ?? []
            Task { await self?.handleExternalChange(changedKeys) }
        }
    }

    private func handleIdentityChange() {
        guard FileManager.default.ubiquityIdentityToken != nil else { return }
        // Account became available — remove the identity-change observer and start sync.
        NotificationCenter.default.removeObserver(
            self,
            name: NSNotification.Name.NSUbiquityIdentityDidChange,
            object: nil
        )
        startSync()
    }

    private func handleExternalChange(_ changedKeys: [String]) {
        for key in changedKeys {
            if let store = SyncableStore(rawValue: key) {
                externalChangesContinuation.yield(store)
            }
        }
    }
}
