/// Pure transition model for system audio interruptions. Keeping policy separate
/// from AVFoundation lets notification sequences be regression-tested on every
/// Swift Package test host while the iOS build verifies the concrete session calls.
public struct AudioInterruptionStateMachine: Sendable {
    public enum Source: Sendable {
        case systemInterruption
        case secondaryAudioHint
    }

    public enum Action: Equatable, Sendable {
        case pauseAndYield
        /// Reactivate the session and resume once. The concrete owner preserves
        /// the item and rebuilds only after a failed post-resume health check.
        case rebuildGraphAndResume
        /// Media services were reset. Rebuild while paused; Apple requires a new
        /// user playback action rather than silently restarting media.
        case rebuildGraphAndStayPaused
        case stayPaused
        case ignore
    }

    public private(set) var isHandling = false
    public private(set) var wasPlaying = false
    /// Durable playback intent is separate from AVPlayer.rate. A route change can
    /// publish rate=0 immediately before the matching interruption notification.
    /// That system pause must not be mistaken for a user pause.
    public private(set) var userWantsPlayback = false
    /// Set only after the final interruption source ends with resume permission.
    /// The owner clears it after one successful session activation or any newer
    /// user, item, route, or media-services transition.
    public private(set) var pendingSystemResume = false
    public private(set) var generation: UInt = 0
    public private(set) var mediaServicesAreLost = false
    public private(set) var wasPlayingBeforeMediaServicesLoss = false
    private var systemInterruptionActive = false
    private var secondaryAudioHintActive = false
    private var systemParticipatedInCycle = false
    private var systemResumePermission: Bool?
    private var hintResumePermission = false

    public init() {}

    /// Every deferred source, quality swap and recovery shares this authority.
    public var allowsAutomaticPlayback: Bool {
        userWantsPlayback && !isHandling && !mediaServicesAreLost
    }

    /// Item selection changes intent, not the system's ownership of audio.
    /// A new item selected during a spoken notification waits for its end.
    public mutating func selectedItem() {
        generation &+= 1
        pendingSystemResume = false
        userWantsPlayback = true
        wasPlaying = isHandling
    }

    public var diagnosticSummary: String {
        "handling=\(isHandling) intent=\(userWantsPlayback) "
            + "wasPlaying=\(wasPlaying) pendingResume=\(pendingSystemResume) "
            + "generation=\(generation)"
    }

    public mutating func began(wasPlaying: Bool) -> Action {
        guard !isHandling else { return .ignore }
        generation &+= 1
        isHandling = true
        pendingSystemResume = false
        if wasPlaying { userWantsPlayback = true }
        self.wasPlaying = wasPlaying || userWantsPlayback
        return .pauseAndYield
    }

    /// Coalesces overlapping AVAudioSession interruption and spoken-prompt hint
    /// notifications into one pause/resume cycle. An end for one source cannot
    /// resume while the other source still owns audio.
    public mutating func sourceBegan(_ source: Source, wasPlaying: Bool) -> Action {
        let hadBlocker = systemInterruptionActive || secondaryAudioHintActive
        switch source {
        case .systemInterruption:
            guard !systemInterruptionActive else { return .ignore }
            systemInterruptionActive = true
            systemParticipatedInCycle = true
        case .secondaryAudioHint:
            guard !secondaryAudioHintActive else { return .ignore }
            secondaryAudioHintActive = true
        }
        if !hadBlocker {
            systemParticipatedInCycle = source == .systemInterruption
            systemResumePermission = nil
            hintResumePermission = false
            return began(wasPlaying: wasPlaying)
        }
        return .ignore
    }

    public mutating func sourceEnded(_ source: Source, shouldResume: Bool) -> Action {
        switch source {
        case .systemInterruption:
            guard systemInterruptionActive else { return .ignore }
            systemInterruptionActive = false
            // `shouldResume` is a recommendation, not the notification that the
            // competing audio owner has yielded. ChatGPT voice input can send a
            // causal `.ended` with no option even though this app was playing and
            // the user never paused it. Preserve that explicit user intent and let
            // the concrete owner use `setActive(true)` as the final arbitration
            // gate. A user/AirPods/Siri pause has already cleared the intent.
            systemResumePermission = shouldResume || userWantsPlayback
        case .secondaryAudioHint:
            guard secondaryAudioHintActive else { return .ignore }
            secondaryAudioHintActive = false
            hintResumePermission = shouldResume
        }
        guard !systemInterruptionActive, !secondaryAudioHintActive else { return .ignore }
        let permitted = systemParticipatedInCycle
            ? systemResumePermission == true
            : hintResumePermission
        systemParticipatedInCycle = false
        systemResumePermission = nil
        hintResumePermission = false
        return ended(shouldResume: permitted)
    }

    public mutating func ended(shouldResume: Bool) -> Action {
        guard isHandling else { return .ignore }
        let resume = shouldResume && wasPlaying && userWantsPlayback
        isHandling = false
        wasPlaying = false
        pendingSystemResume = resume
        return resume ? .rebuildGraphAndResume : .stayPaused
    }

    /// Records actual playback without creating a new interruption generation.
    /// Initial audio-first playback reaches this point only after a user selected
    /// an item and its first buffer became playable.
    public mutating func playbackBecameActive() {
        guard !isHandling, !mediaServicesAreLost else { return }
        userWantsPlayback = true
    }

    public func acceptsPendingResume(generation: UInt) -> Bool {
        self.generation == generation
            && pendingSystemResume
            && userWantsPlayback
            && !isHandling
            && !mediaServicesAreLost
    }

    @discardableResult
    public mutating func completePendingResume(generation: UInt) -> Bool {
        guard acceptsPendingResume(generation: generation) else { return false }
        pendingSystemResume = false
        return true
    }

    public mutating func cancelPendingResume() {
        pendingSystemResume = false
        generation &+= 1
    }

    /// Recovers from an interruption whose matching `.ended` notification was
    /// never delivered. Apple documents that begin/end notifications are not a
    /// guaranteed pair. A deliberate Play from the user is therefore allowed to
    /// take ownership again after the competing audio app has yielded, while a
    /// media-services outage remains non-recoverable until reset arrives.
    public mutating func userRequestedPlay() -> Action {
        guard !mediaServicesAreLost else { return .stayPaused }
        clearAudioSources()
        generation &+= 1
        isHandling = false
        wasPlaying = false
        userWantsPlayback = true
        pendingSystemResume = false
        return .rebuildGraphAndResume
    }

    /// A user or Siri pause received during an interruption wins over the
    /// pre-interruption resume intent. It also invalidates any in-flight seek or
    /// graph rebuild completion from an older generation.
    public mutating func userPaused() {
        generation &+= 1
        wasPlaying = false
        userWantsPlayback = false
        pendingSystemResume = false
        wasPlayingBeforeMediaServicesLoss = false
    }

    public mutating func routeBecameUnavailable(wasPlaying: Bool = false) -> Action {
        generation &+= 1
        self.wasPlaying = false
        pendingSystemResume = false
        if wasPlaying { userWantsPlayback = true }
        return .pauseAndYield
    }

    public mutating func routeBecameAvailable() -> Action {
        guard !isHandling, !pendingSystemResume else { return .stayPaused }
        generation &+= 1
        return .stayPaused
    }

    public mutating func mediaServicesLost(wasPlaying: Bool) -> Action {
        generation &+= 1
        mediaServicesAreLost = true
        wasPlayingBeforeMediaServicesLoss = wasPlaying
        self.wasPlaying = false
        pendingSystemResume = false
        return .pauseAndYield
    }

    public mutating func mediaServicesReset() -> Action {
        generation &+= 1
        guard mediaServicesAreLost else { return .stayPaused }
        mediaServicesAreLost = false
        wasPlayingBeforeMediaServicesLoss = false
        userWantsPlayback = false
        pendingSystemResume = false
        return .rebuildGraphAndStayPaused
    }

    public mutating func enteredBackground(
        playbackAllowed: Bool,
        wasPlaying: Bool
    ) -> Action {
        guard wasPlaying, !playbackAllowed else { return .ignore }
        generation &+= 1
        self.wasPlaying = false
        userWantsPlayback = false
        pendingSystemResume = false
        return .stayPaused
    }

    public mutating func enteredForeground() -> Action {
        return .ignore
    }

    public mutating func invalidatePendingRecovery() {
        generation &+= 1
        pendingSystemResume = false
    }

    public mutating func reset() {
        generation &+= 1
        isHandling = false
        wasPlaying = false
        userWantsPlayback = false
        pendingSystemResume = false
        mediaServicesAreLost = false
        wasPlayingBeforeMediaServicesLoss = false
        clearAudioSources()
    }

    private mutating func clearAudioSources() {
        systemInterruptionActive = false
        secondaryAudioHintActive = false
        systemParticipatedInCycle = false
        systemResumePermission = nil
        hintResumePermission = false
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
