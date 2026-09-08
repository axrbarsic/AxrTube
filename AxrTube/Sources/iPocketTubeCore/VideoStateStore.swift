import Foundation

// MARK: - VideoStateStore
//
// Persists per-video watch position and progress fraction across sessions.
// Mirrors Android's VideoStateService + VideoStateController.
//
// Thread-safe: implemented as a Swift actor.

public actor VideoStateStore: UserDefaultsBackedStore {

    // MARK: - State

    public struct State: Codable, Sendable {
        /// Saved playback position in seconds.
        public var position: TimeInterval
        /// Fraction watched: 0.0 – 1.0
        public var watchedFraction: Double
        public var duration: TimeInterval
        public var updatedAt: Date
        public var isCompleted: Bool

        public init(
            position: TimeInterval,
            watchedFraction: Double,
            duration: TimeInterval = 0,
            updatedAt: Date = Date(),
            isCompleted: Bool = false
        ) {
            self.position = position
            self.watchedFraction = watchedFraction
            self.duration = duration
            self.updatedAt = updatedAt
            self.isCompleted = isCompleted
        }

        private enum CodingKeys: String, CodingKey {
            case position, watchedFraction, duration, updatedAt, timestamp, isCompleted
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            position = try container.decode(TimeInterval.self, forKey: .position)
            watchedFraction = try container.decode(Double.self, forKey: .watchedFraction)
            duration = try container.decodeIfPresent(TimeInterval.self, forKey: .duration) ?? 0
            updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt)
                ?? container.decodeIfPresent(Date.self, forKey: .timestamp)
                ?? Date.distantPast
            isCompleted = try container.decodeIfPresent(Bool.self, forKey: .isCompleted)
                ?? (watchedFraction >= PlaybackPositionPolicy.completionFraction)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(position, forKey: .position)
            try container.encode(watchedFraction, forKey: .watchedFraction)
            try container.encode(duration, forKey: .duration)
            try container.encode(updatedAt, forKey: .updatedAt)
            try container.encode(isCompleted, forKey: .isCompleted)
        }
    }

    // MARK: - Singleton

    public static let shared = VideoStateStore()

    // MARK: - Private

    static let defaultsKey = "st_video_states"
    private static let maxEntries = 1_000

    private var states: [String: State] = [:]
    let defaults: UserDefaults
    private let atomicFileURL: URL?

    private init() {
        self.defaults = .standard
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        self.atomicFileURL = support?
            .appendingPathComponent("iPocketTube", isDirectory: true)
            .appendingPathComponent("playback-positions.json")
        if let atomicFileURL,
           let data = try? Data(contentsOf: atomicFileURL),
           let loaded = try? JSONDecoder().decode([String: State].self, from: data) {
            states = loaded
        } else if let loaded = Self.loadFrom(.standard) {
            states = loaded
        }
    }

    /// Designated initializer for unit testing. Pass a unique `suiteName` string
    /// (e.g. `"test-\(UUID().uuidString)"`) to get a fully isolated store with
    /// no shared `UserDefaults` state — `String` is `Sendable` so this crosses
    /// actor isolation boundaries cleanly in Swift 6 strict concurrency.
    init(suiteName: String) {
        self.defaults = UserDefaults(suiteName: suiteName) ?? .standard
        self.atomicFileURL = nil
        if let loaded = Self.loadFrom(self.defaults) { states = loaded }
    }

    // MARK: - Public API

    /// Returns the saved state for `videoId`, or nil if nothing was saved.
    public func state(for videoId: String) -> State? {
        states[videoId]
    }

    /// Persists one stable media identity. Completed items remain explicit so a
    /// relaunch starts from zero instead of the last few seconds.
    public func save(videoId: String, position: TimeInterval, duration: TimeInterval) {
        guard position.isFinite, duration.isFinite, duration > 0 else { return }
        let clamped = min(max(position, 0), duration)
        let fraction = min(clamped / duration, 1.0)
        if clamped < 1 {
            states.removeValue(forKey: videoId)
        } else {
            states[videoId] = State(
                position: clamped,
                watchedFraction: fraction,
                duration: duration,
                isCompleted: PlaybackPositionPolicy.isCompleted(position: clamped, duration: duration)
            )
            prune()
        }
        persist()
    }

    public func restoredPosition(for videoId: String, actualDuration: TimeInterval) -> TimeInterval {
        guard let state = states[videoId] else { return 0 }
        return PlaybackPositionPolicy.restoredPosition(state: state, actualDuration: actualDuration)
    }

    /// Removes any saved position for `videoId` (e.g. when the user finishes watching).
    public func clear(videoId: String) {
        states.removeValue(forKey: videoId)
        persist()
    }

    // MARK: - UserDefaultsBackedStore

    func encodedValue() -> [String: State] { states }
    func decodeValue(_ decoded: [String: State]) { states = decoded }

    func afterPersist() {
        let value = states
        Task { await iCloudSyncManager.shared.push(.videoState, value) }
    }

    func persist() {
        do {
            let value = states
            let data = try JSONEncoder().encode(value)
            if let atomicFileURL {
                try FileManager.default.createDirectory(
                    at: atomicFileURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try data.write(to: atomicFileURL, options: .atomic)
            }
            defaults.set(data, forKey: Self.defaultsKey)
            afterPersist()
        } catch {
            // Keep the previous durable snapshot. Playback must never be blocked by persistence.
        }
    }

    // MARK: - Persistence

    private func prune() {
        guard states.count > Self.maxEntries else { return }
        let sorted = states.sorted { $0.value.updatedAt < $1.value.updatedAt }
        sorted.prefix(states.count - Self.maxEntries).forEach { states.removeValue(forKey: $0.key) }
    }
}

public enum PlaybackPositionPolicy {
    public static let completionFraction = 0.95
    public static let completionRemainingSeconds: TimeInterval = 10
    public static let periodicSaveInterval: TimeInterval = 5

    /// Unknown duration must not erase a valid observed playback position.
    public static func displayedPosition(observed: TimeInterval, duration: TimeInterval) -> TimeInterval {
        guard observed.isFinite else { return 0 }
        let position = max(0, observed)
        return duration.isFinite && duration > 0 ? min(position, duration) : position
    }

    public static func isCompleted(position: TimeInterval, duration: TimeInterval) -> Bool {
        guard duration.isFinite, duration > 0, position.isFinite else { return false }
        let clamped = min(max(position, 0), duration)
        return clamped / duration >= completionFraction
            || duration - clamped <= completionRemainingSeconds
    }

    public static func restoredPosition(
        state: VideoStateStore.State,
        actualDuration: TimeInterval
    ) -> TimeInterval {
        guard actualDuration.isFinite, actualDuration > 0,
              state.position.isFinite, state.position > 0,
              !state.isCompleted else { return 0 }
        return min(max(state.position, 0), max(0, actualDuration - 0.5))
    }

    public static func shouldWritePeriodicCheckpoint(
        lastWrite: Date?,
        now: Date
    ) -> Bool {
        guard let lastWrite else { return true }
        return now.timeIntervalSince(lastWrite) >= periodicSaveInterval
    }

    /// AVPlayer can briefly publish zero while an existing item reconnects to its
    /// output route. That lifecycle artifact must not move the visible scrubber or
    /// Now Playing elapsed time back to the beginning. Explicit seeks update the
    /// current value first, so a genuine user seek to zero remains accepted.
    public static func reconciledObservedPosition(
        observed: TimeInterval,
        current: TimeInterval
    ) -> TimeInterval {
        guard observed.isFinite, observed >= 0 else { return max(0, current) }
        guard current.isFinite, current >= 0 else { return observed }
        if observed < 0.05, current > 1 { return current }
        return observed
    }
}
