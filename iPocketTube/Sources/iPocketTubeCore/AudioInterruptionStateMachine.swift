/// Pure transition model for system audio interruptions. Keeping policy separate
/// from AVFoundation lets notification sequences be regression-tested on every
/// Swift Package test host while the iOS build verifies the concrete session calls.
public struct AudioInterruptionStateMachine: Sendable {
    public enum Action: Equatable, Sendable {
        case pauseAndYield
        /// Reactivate the session, rebuild the presentation graph, and resume once.
        case rebuildGraphAndResume
        /// Media services were reset. Rebuild while paused; Apple requires a new
        /// user playback action rather than silently restarting media.
        case rebuildGraphAndStayPaused
        case stayPaused
        case ignore
    }

    public private(set) var isHandling = false
    public private(set) var wasPlaying = false
    public private(set) var generation: UInt = 0
    public private(set) var mediaServicesAreLost = false
    public private(set) var wasPlayingBeforeMediaServicesLoss = false

    public init() {}

    public mutating func began(wasPlaying: Bool) -> Action {
        guard !isHandling else { return .ignore }
        generation &+= 1
        isHandling = true
        self.wasPlaying = wasPlaying
        return .pauseAndYield
    }

    public mutating func ended(shouldResume: Bool) -> Action {
        guard isHandling else { return .ignore }
        let resume = shouldResume && wasPlaying
        isHandling = false
        wasPlaying = false
        return resume ? .rebuildGraphAndResume : .stayPaused
    }

    /// Recovers from an interruption whose matching `.ended` notification was
    /// never delivered. Apple documents that begin/end notifications are not a
    /// guaranteed pair. A deliberate Play from the user is therefore allowed to
    /// take ownership again after the competing audio app has yielded, while a
    /// media-services outage remains non-recoverable until reset arrives.
    public mutating func userRequestedPlay() -> Action {
        guard !mediaServicesAreLost else { return .stayPaused }
        generation &+= 1
        isHandling = false
        wasPlaying = false
        return .rebuildGraphAndResume
    }

    /// A user or Siri pause received during an interruption wins over the
    /// pre-interruption resume intent. It also invalidates any in-flight seek or
    /// graph rebuild completion from an older generation.
    public mutating func userPaused() {
        generation &+= 1
        wasPlaying = false
        wasPlayingBeforeMediaServicesLoss = false
    }

    public mutating func routeBecameUnavailable() -> Action {
        generation &+= 1
        wasPlaying = false
        return .pauseAndYield
    }

    public mutating func routeBecameAvailable() -> Action {
        generation &+= 1
        return .stayPaused
    }

    public mutating func mediaServicesLost(wasPlaying: Bool) -> Action {
        generation &+= 1
        mediaServicesAreLost = true
        wasPlayingBeforeMediaServicesLoss = wasPlaying
        self.wasPlaying = false
        return .pauseAndYield
    }

    public mutating func mediaServicesReset() -> Action {
        generation &+= 1
        guard mediaServicesAreLost else { return .stayPaused }
        mediaServicesAreLost = false
        wasPlayingBeforeMediaServicesLoss = false
        return .rebuildGraphAndStayPaused
    }

    public mutating func enteredBackground(
        playbackAllowed: Bool,
        wasPlaying: Bool
    ) -> Action {
        guard wasPlaying, !playbackAllowed else { return .ignore }
        generation &+= 1
        self.wasPlaying = false
        return .stayPaused
    }

    public mutating func enteredForeground() -> Action {
        return .ignore
    }

    public mutating func invalidatePendingRecovery() {
        generation &+= 1
    }

    public mutating func reset() {
        generation &+= 1
        isHandling = false
        wasPlaying = false
        mediaServicesAreLost = false
        wasPlayingBeforeMediaServicesLoss = false
    }
}

/// Generation gate for the process-wide Now Playing owner. Async artwork,
/// finalisation, or teardown callbacks may only publish/clear the source whose
/// token they captured; a callback from an older track is ignored.
public struct NowPlayingSourceState: Equatable, Sendable {
    public private(set) var generation: UInt64 = 0
    public private(set) var itemKey: String?

    public init() {}

    @discardableResult
    public mutating func activate(itemKey: String) -> UInt64 {
        if self.itemKey != itemKey {
            generation &+= 1
            self.itemKey = itemKey
        }
        return generation
    }

    public func accepts(generation: UInt64, itemKey: String) -> Bool {
        self.generation == generation && self.itemKey == itemKey
    }

    public mutating func clear(generation: UInt64) -> Bool {
        guard self.generation == generation, itemKey != nil else { return false }
        self.generation &+= 1
        itemKey = nil
        return true
    }
}
