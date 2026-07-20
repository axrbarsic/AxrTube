import Foundation

#if canImport(ActivityKit)
import ActivityKit
#endif

public enum PlaybackLiveActivityMode: String, Codable, CaseIterable, Sendable {
    case off
    case minimal
    case progress
    case waveform
    case line
    case automatic
}

/// AxrTube uses the system Now Playing card as the single reliable playback
/// surface. Download activities remain independent and are not affected.
public enum PlaybackLockScreenPolicy {
    public static let usesPlaybackLiveActivity = false
}

public enum PlaybackLiveActivityPresentation: String, Codable, Equatable, Sendable {
    case minimal
    case progress
    case waveform
    case line
}

public enum PlaybackLiveActivityCompactContent: Equatable, Hashable, Sendable {
    case playbackState
    case remainingTime
    case waveform
    case caption
}

public enum PlaybackLiveActivityMinimalContent: Equatable, Hashable, Sendable {
    case brand
    case progress
    case waveform
    case caption
}

/// Keeps every ActivityKit surface tied to the same resolved presentation.
/// Automatic mode deliberately resolves to one of these four profiles.
public enum PlaybackLiveActivitySurfacePolicy {
    public static func compactContent(
        for presentation: PlaybackLiveActivityPresentation
    ) -> PlaybackLiveActivityCompactContent {
        switch presentation {
        case .minimal: .playbackState
        case .progress: .remainingTime
        case .waveform: .waveform
        case .line: .caption
        }
    }

    public static func minimalContent(
        for presentation: PlaybackLiveActivityPresentation
    ) -> PlaybackLiveActivityMinimalContent {
        switch presentation {
        case .minimal: .brand
        case .progress: .progress
        case .waveform: .waveform
        case .line: .caption
        }
    }
}

public enum PlaybackLiveActivityPolicy {
    public static func presentation(
        for mode: PlaybackLiveActivityMode,
        transcriptLine: String?,
        duration: TimeInterval
    ) -> PlaybackLiveActivityPresentation? {
        switch mode {
        case .off: nil
        case .minimal: .minimal
        case .progress: .progress
        case .waveform: .waveform
        case .line: .line
        case .automatic:
            if cleaned(transcriptLine) != nil { .line }
            else if duration.isFinite, duration > 0 { .progress }
            else { .minimal }
        }
    }

    public static func displayLine(
        transcriptLine: String?,
        title: String,
        author: String
    ) -> String {
        if let transcript = cleaned(transcriptLine) { return transcript }
        if let title = cleaned(title) { return title }
        if let author = cleaned(author) { return author }
        return "AxrTube"
    }

    public static func waveformLevels(videoID: String, elapsed: TimeInterval) -> [Double] {
        let bucket = max(0, Int(elapsed / 15))
        let seed = videoID.unicodeScalars.reduce(bucket &+ 17) { ($0 &* 31) &+ Int($1.value) }
        return (0..<7).map { index in
            let mixed = UInt(bitPattern: seed &+ index &* 37 &+ bucket &* (index &+ 5))
            return 0.22 + (Double(mixed % 67) / 100)
        }
    }

    private static func cleaned(_ value: String?) -> String? {
        guard let value else { return nil }
        let result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }
}

public enum PlaybackLiveActivityLifecycleAction: Equatable, Sendable {
    case none
    case request
    case update
    case replace
    case end
}

public struct PlaybackLiveActivityLifecycle: Equatable, Sendable {
    public private(set) var activeVideoID: String?

    public init(activeVideoID: String? = nil) {
        self.activeVideoID = activeVideoID
    }

    public mutating func reconcile(mode: PlaybackLiveActivityMode, videoID: String?) -> PlaybackLiveActivityLifecycleAction {
        guard mode != .off, let videoID, !videoID.isEmpty else {
            guard activeVideoID != nil else { return .none }
            activeVideoID = nil
            return .end
        }
        guard let activeVideoID else {
            self.activeVideoID = videoID
            return .request
        }
        guard activeVideoID == videoID else {
            self.activeVideoID = videoID
            return .replace
        }
        return .update
    }

    public mutating func reset() {
        activeVideoID = nil
    }
}

public struct LiveActivityArbitrationLease: Equatable, Hashable, Sendable {
    public enum Role: Equatable, Hashable, Sendable {
        case download
        case playback
    }

    public let role: Role
    public let itemID: String
    public let generation: UInt64

    public init(role: Role, itemID: String, generation: UInt64) {
        self.role = role
        self.itemID = itemID
        self.generation = generation
    }
}

public struct LiveActivityDownloadRegistration: Equatable, Sendable {
    public let lease: LiveActivityArbitrationLease
    public let shouldPresent: Bool
    public let preemptedDownload: LiveActivityArbitrationLease?
}

public struct LiveActivityPlaybackClaim: Equatable, Sendable {
    public let lease: LiveActivityArbitrationLease
    public let preemptedDownload: LiveActivityArbitrationLease?
}

public struct LiveActivityArbitrationReset: Equatable, Sendable {
    public let playback: LiveActivityArbitrationLease?
    public let download: LiveActivityArbitrationLease?
}

/// A platform-independent ownership policy for the two existing ActivityKit owners.
/// It never creates, updates, or ends an activity itself.
public struct LiveActivityArbitrationPolicy: Equatable, Sendable {
    public private(set) var playbackLease: LiveActivityArbitrationLease?
    public private(set) var downloadLease: LiveActivityArbitrationLease?
    public private(set) var isDownloadPresented = false

    private var generation: UInt64 = 0

    public init() {}

    public mutating func beginDownload(itemID: String) -> LiveActivityDownloadRegistration {
        generation &+= 1
        let lease = LiveActivityArbitrationLease(
            role: .download,
            itemID: itemID,
            generation: generation
        )
        // A newer logical download replaces the prior presentation candidate even
        // when that prior candidate is currently suppressed by playback.
        let preemptedDownload = downloadLease
        let shouldPresent = playbackLease == nil
        downloadLease = lease
        isDownloadPresented = shouldPresent
        return LiveActivityDownloadRegistration(
            lease: lease,
            shouldPresent: shouldPresent,
            preemptedDownload: preemptedDownload
        )
    }

    @discardableResult
    public mutating func finishDownload(_ lease: LiveActivityArbitrationLease) -> Bool {
        guard downloadLease == lease else { return false }
        downloadLease = nil
        isDownloadPresented = false
        return true
    }

    public mutating func claimPlayback(itemID: String) -> LiveActivityPlaybackClaim {
        generation &+= 1
        let lease = LiveActivityArbitrationLease(
            role: .playback,
            itemID: itemID,
            generation: generation
        )
        let preemptedDownload = isDownloadPresented ? downloadLease : nil
        playbackLease = lease
        if preemptedDownload != nil {
            isDownloadPresented = false
        }
        return LiveActivityPlaybackClaim(
            lease: lease,
            preemptedDownload: preemptedDownload
        )
    }

    public mutating func releasePlayback(
        _ lease: LiveActivityArbitrationLease
    ) -> LiveActivityArbitrationLease? {
        guard playbackLease == lease else { return nil }
        playbackLease = nil
        guard let downloadLease, !isDownloadPresented else { return nil }
        isDownloadPresented = true
        return downloadLease
    }

    public mutating func resetAfterLaunch() -> LiveActivityArbitrationReset {
        let reset = LiveActivityArbitrationReset(
            playback: playbackLease,
            download: downloadLease
        )
        generation &+= 1
        playbackLease = nil
        downloadLease = nil
        isDownloadPresented = false
        return reset
    }
}

#if canImport(ActivityKit) && os(iOS)
@available(iOS 16.1, *)
public struct PlaybackActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable, Sendable {
        public let presentation: PlaybackLiveActivityPresentation
        public let isPlaying: Bool
        public let elapsed: TimeInterval
        public let duration: TimeInterval
        public let line: String
        public let waveformLevels: [Double]
        public let updatedAt: Date

        public init(
            presentation: PlaybackLiveActivityPresentation,
            isPlaying: Bool,
            elapsed: TimeInterval,
            duration: TimeInterval,
            line: String,
            waveformLevels: [Double],
            updatedAt: Date
        ) {
            self.presentation = presentation
            self.isPlaying = isPlaying
            self.elapsed = elapsed
            self.duration = duration
            self.line = line
            self.waveformLevels = waveformLevels
            self.updatedAt = updatedAt
        }
    }

    public let videoID: String
    public let title: String
    public let author: String

    public init(videoID: String, title: String, author: String) {
        self.videoID = videoID
        self.title = title
        self.author = author
    }
}
#endif
