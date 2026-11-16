import Foundation
import Network
import os

/// How far ahead the player may buffer once the first frame is on screen.
/// AVPlayer's automatic choice keeps only tens of seconds, which a weak or
/// flapping connection exhausts quickly. A longer target keeps downloading
/// while the connection is alive (also while paused) so a drop-out plays
/// from the buffer.
public enum PlaybackBufferPolicy {
    /// Video: a few minutes ahead; AVPlayer still trims under memory pressure.
    public static let videoForwardBuffer: TimeInterval = 240
    /// Audio is cheap (≈1 MB per minute), so buffer much further.
    public static let audioOnlyForwardBuffer: TimeInterval = 900

    public static func steadyForwardBuffer(audioOnly: Bool) -> TimeInterval {
        audioOnly ? audioOnlyForwardBuffer : videoForwardBuffer
    }
}

/// What to do while playback waits for data.
public enum StallRecoveryAction: Equatable, Sendable {
    /// Leave AVPlayer alone: it is offline or data is still arriving.
    case wait
    /// No data for a while on a live connection: seek in place to restart
    /// the stuck request.
    case nudge
    /// Repeated nudges did not help: reload the stream (URL likely expired).
    case escalate
}

/// Weak-network stall decisions. A seek discards the partially downloaded
/// segment and a reload discards the whole buffer, so neither happens while
/// the device is offline or bytes are still flowing.
public enum StallRecoveryPolicy {
    /// Data counts as flowing if the buffered end grew within this window.
    public static let progressWindow: TimeInterval = 10
    /// Minimum spacing between nudges.
    public static let nudgeSpacing: TimeInterval = 10
    public static let maxNudges = 2
    /// A stall must last this long on a live connection before reloading.
    public static let escalateAfter: TimeInterval = 30

    public static func decide(
        networkAvailable: Bool,
        secondsSinceBufferGrowth: TimeInterval,
        secondsSinceLastNudge: TimeInterval,
        nudges: Int,
        secondsStalled: TimeInterval
    ) -> StallRecoveryAction {
        guard networkAvailable else { return .wait }
        guard secondsSinceBufferGrowth >= progressWindow else { return .wait }
        guard secondsSinceLastNudge >= nudgeSpacing else { return .wait }
        if nudges < maxNudges { return .nudge }
        return secondsStalled >= escalateAfter ? .escalate : .wait
    }
}

/// Process-wide "is there a usable network path" flag.
public final class NetworkPathObserver: Sendable {
    public static let shared = NetworkPathObserver()

    private let monitor = NWPathMonitor()
    private let state = OSAllocatedUnfairLock(initialState: (available: true, mobile: false))

    private init() {
        monitor.pathUpdateHandler = { [state] path in
            state.withLock {
                $0 = (path.status == .satisfied, path.isExpensive || path.isConstrained)
            }
        }
        monitor.start(queue: DispatchQueue(label: "axrtube.network-path", qos: .utility))
    }

    public var isAvailable: Bool { state.withLock { $0.available } }
    /// Cellular, personal hotspot or Low Data Mode.
    public var isMobile: Bool { state.withLock { $0.mobile } }
}

/// Whether a video should stream as audio only («Экономия трафика» or the
/// explicit «Только аудио»), unless the user asked for video for it.
public enum DataSaverPolicy {
    public static func streamsAudioOnly(
        mode: AppSettings.DataSaverMode, audioOnlySetting: Bool, onMobileNetwork: Bool, videoRequested: Bool
    ) -> Bool {
        if videoRequested { return false }
        if audioOnlySetting { return true }
        switch mode {
        case .off: return false
        case .always: return true
        case .cellular: return onMobileNetwork
        }
    }
}
