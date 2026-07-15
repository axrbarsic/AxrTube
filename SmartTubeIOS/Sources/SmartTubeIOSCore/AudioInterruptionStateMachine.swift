/// Pure transition model for system audio interruptions. Keeping policy separate
/// from AVFoundation lets notification sequences be regression-tested on every
/// Swift Package test host while the iOS build verifies the concrete session calls.
public struct AudioInterruptionStateMachine: Sendable {
    public enum Action: Equatable, Sendable {
        case pauseAndYield
        case activateAndResume
        case stayPaused
        case ignore
    }

    public private(set) var isHandling = false
    public private(set) var wasPlaying = false
    public private(set) var generation: UInt = 0

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
        return resume ? .activateAndResume : .stayPaused
    }

    public mutating func invalidatePendingRecovery() {
        generation &+= 1
    }

    public mutating func reset() {
        generation &+= 1
        isHandling = false
        wasPlaying = false
    }
}
