import Foundation

/// Pure policy for starting playback from a growing local audio cache.
/// Production uses the same thresholds as the focused tests.
public struct ProgressiveAudioStateMachine: Sendable, Equatable {
    public static let defaultInitialBufferBytes: Int64 = 512 * 1024

    public private(set) var downloadedBytes: Int64 = 0
    public private(set) var expectedBytes: Int64 = 0
    public private(set) var playbackStarted = false
    public private(set) var completed = false
    public let initialBufferBytes: Int64

    public init(initialBufferBytes: Int64 = defaultInitialBufferBytes) {
        self.initialBufferBytes = max(64 * 1024, initialBufferBytes)
    }

    public var downloadProgress: Double {
        guard expectedBytes > 0 else { return 0 }
        return min(1, Double(downloadedBytes) / Double(expectedBytes))
    }

    public var canStartPlayback: Bool {
        guard downloadedBytes > 0 else { return false }
        let safeThreshold = expectedBytes > 0
            ? min(initialBufferBytes, max(64 * 1024, expectedBytes / 20))
            : initialBufferBytes
        return downloadedBytes >= safeThreshold || completed
    }

    @discardableResult
    public mutating func receive(downloaded: Int64, expected: Int64) -> Bool {
        downloadedBytes = max(downloadedBytes, max(0, downloaded))
        expectedBytes = max(expectedBytes, max(0, expected))
        guard !playbackStarted, canStartPlayback else { return false }
        playbackStarted = true
        return true
    }

    @discardableResult
    public mutating func finish(downloaded: Int64, expected: Int64) -> Bool {
        downloadedBytes = max(downloadedBytes, max(0, downloaded))
        expectedBytes = max(expectedBytes, max(0, expected))
        completed = true
        guard !playbackStarted else { return false }
        playbackStarted = true
        return true
    }

    /// AVPlayer's resource loader can request an uncached time range on demand,
    /// so seek is bounded by media duration, not by sequential download progress.
    public func clampedSeekTime(_ requested: TimeInterval, duration: TimeInterval) -> TimeInterval {
        guard duration.isFinite, duration > 0 else { return max(0, requested) }
        return min(max(0, requested), duration)
    }
}

/// Single source of truth for the Downloads now-playing card. Playback,
/// downloader and finalizer callbacks all carry the command generation that
/// created them; callbacks from a superseded command are ignored here rather
/// than being allowed to overwrite the current UI independently.
public struct AudioFirstAuthoritativeState: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        case idle
        case resolving
        case buffering
        case reconnecting
        case waitingForWiFi
        case playing
        case finalizing
        case finalizationPending(String)
        case completed
        case terminalFailure(String)
    }

    public enum Event: Sendable, Equatable {
        case begin(generation: UInt64, durableProgress: Double)
        case buffering(generation: UInt64)
        case reconnecting(generation: UInt64)
        case waitingForWiFi(generation: UInt64)
        case playbackInstalled(generation: UInt64)
        case timeline(generation: UInt64, position: TimeInterval)
        case userSeek(generation: UInt64, position: TimeInterval)
        case downloadProgress(generation: UInt64, value: Double)
        case finalizationStarted(generation: UInt64)
        case finalizationFailed(generation: UInt64, message: String)
        case completed(generation: UInt64)
        case exhaustedFailure(generation: UInt64, message: String)
        case close
    }

    public private(set) var generation: UInt64 = 0
    public private(set) var phase: Phase = .idle
    public private(set) var hasPlayableSource = false
    public private(set) var playbackPosition: TimeInterval = 0
    public private(set) var downloadProgress: Double = 0
    private var pendingSeekTarget: TimeInterval?

    public init() {}

    /// Returns false for stale events so callers can avoid all associated side
    /// effects (manifest writes, visible status changes and diagnostics).
    @discardableResult
    public mutating func reduce(_ event: Event) -> Bool {
        if case .close = event {
            phase = .idle
            hasPlayableSource = false
            playbackPosition = 0
            downloadProgress = 0
            pendingSeekTarget = nil
            return true
        }

        let eventGeneration = event.generation
        if case .begin(let newGeneration, let durableProgress) = event {
            generation = newGeneration
            phase = .resolving
            hasPlayableSource = false
            playbackPosition = 0
            downloadProgress = Self.clamp(durableProgress)
            pendingSeekTarget = nil
            return true
        }
        guard eventGeneration == generation else { return false }

        switch event {
        case .begin, .close:
            return false
        case .buffering:
            phase = .buffering
        case .reconnecting:
            phase = .reconnecting
        case .waitingForWiFi:
            phase = .waitingForWiFi
        case .playbackInstalled:
            hasPlayableSource = true
            if phase == .resolving { phase = .buffering }
        case .timeline(_, let position):
            guard position.isFinite, position >= 0 else { return false }
            hasPlayableSource = true
            if let target = pendingSeekTarget {
                guard abs(position - target) <= 1.5 else { return false }
                pendingSeekTarget = nil
                playbackPosition = position
            } else {
            // Periodic observers can emit an old value after hydration/item
            // replacement. Only an explicit user seek is allowed to move back.
                if position + 0.75 >= playbackPosition {
                    playbackPosition = max(playbackPosition, position)
                }
            }
            switch phase {
            case .completed, .finalizing, .finalizationPending:
                break
            default:
                phase = .playing
            }
        case .userSeek(_, let position):
            guard position.isFinite else { return false }
            playbackPosition = max(0, position)
            pendingSeekTarget = playbackPosition
        case .downloadProgress(_, let value):
            downloadProgress = max(downloadProgress, Self.clamp(value))
        case .finalizationStarted:
            phase = .finalizing
        case .finalizationFailed(_, let message):
            phase = hasPlayableSource ? .finalizationPending(message) : .terminalFailure(message)
        case .completed:
            hasPlayableSource = true
            downloadProgress = 1
            phase = .completed
        case .exhaustedFailure(_, let message):
            // A downloader/finalizer failure cannot invalidate an AVPlayer item
            // that already proved it can advance. Keep the timeline and expose a
            // resumable state instead of a contradictory terminal error.
            phase = hasPlayableSource ? .finalizationPending(message) : .terminalFailure(message)
        }
        return true
    }

    private static func clamp(_ value: Double) -> Double {
        min(1, max(0, value.isFinite ? value : 0))
    }
}

private extension AudioFirstAuthoritativeState.Event {
    var generation: UInt64 {
        switch self {
        case .begin(let generation, _), .buffering(let generation),
             .reconnecting(let generation), .waitingForWiFi(let generation),
             .playbackInstalled(let generation), .timeline(let generation, _),
             .userSeek(let generation, _), .downloadProgress(let generation, _),
             .finalizationStarted(let generation), .finalizationFailed(let generation, _),
             .completed(let generation), .exhaustedFailure(let generation, _):
            generation
        case .close:
            0
        }
    }
}
