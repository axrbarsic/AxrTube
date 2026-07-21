#if os(iOS)
import ActivityKit
import Foundation
import OSLog
import iPocketTubeCore

private let playbackActivityLog = Logger(
    subsystem: "com.alexlane.smarttube.local",
    category: "PlaybackLiveActivity"
)

@available(iOS 16.1, *)
enum LiveActivityDownloadDirective {
    case suppress(LiveActivityArbitrationLease)
    case restore(LiveActivityArbitrationLease)
}

/// Shares only ownership decisions. The existing download and playback owners
/// remain responsible for their own ActivityKit request, update, and end calls.
@available(iOS 16.1, *)
@MainActor
final class LiveActivityArbitrationCenter {
    typealias DownloadHandler = @MainActor (LiveActivityDownloadDirective) async -> Void

    static let shared = LiveActivityArbitrationCenter()

    private var policy = LiveActivityArbitrationPolicy()
    private var downloadHandlers: [LiveActivityArbitrationLease: DownloadHandler] = [:]

    private init() {}

    func registerDownload(
        itemID: String,
        handler: @escaping DownloadHandler
    ) async -> (lease: LiveActivityArbitrationLease, shouldPresent: Bool) {
        let registration = policy.beginDownload(itemID: itemID)
        let preemptedHandler = registration.preemptedDownload.flatMap {
            downloadHandlers.removeValue(forKey: $0)
        }
        downloadHandlers[registration.lease] = handler
        if let preemptedDownload = registration.preemptedDownload,
           let preemptedHandler {
            await preemptedHandler(.suppress(preemptedDownload))
        }
        return (
            registration.lease,
            registration.shouldPresent && allowsDownloadPresentation(registration.lease)
        )
    }

    func finishDownload(_ lease: LiveActivityArbitrationLease) {
        _ = policy.finishDownload(lease)
        downloadHandlers.removeValue(forKey: lease)
    }

    func claimPlayback(itemID: String) async -> LiveActivityArbitrationLease {
        let claim = policy.claimPlayback(itemID: itemID)
        if let preemptedDownload = claim.preemptedDownload,
           let handler = downloadHandlers[preemptedDownload] {
            await handler(.suppress(preemptedDownload))
        }
        return claim.lease
    }

    func releasePlayback(_ lease: LiveActivityArbitrationLease) async {
        guard let restoredDownload = policy.releasePlayback(lease),
              let handler = downloadHandlers[restoredDownload] else { return }
        await handler(.restore(restoredDownload))
    }

    func allowsDownloadPresentation(_ lease: LiveActivityArbitrationLease) -> Bool {
        policy.downloadLease == lease
            && policy.playbackLease == nil
            && policy.isDownloadPresented
    }

    func resetAfterLaunch() async {
        let reset = policy.resetAfterLaunch()
        let handler = reset.download.flatMap { downloadHandlers[$0] }
        downloadHandlers.removeAll()
        if let download = reset.download, let handler {
            await handler(.suppress(download))
        }
    }
}

@available(iOS 16.1, *)
@MainActor
public final class PlaybackLiveActivityController {
    private struct Snapshot {
        let video: Video
        let isPlaying: Bool
        let elapsed: TimeInterval
        let duration: TimeInterval
        let transcriptLine: String?
    }

    private struct PublishedSignature: Equatable {
        let videoID: String
        let presentation: PlaybackLiveActivityPresentation
        let isPlaying: Bool
        let line: String
        let timeBucket: Int
    }

    private let settingsStore: SettingsStore
    private var lifecycle = PlaybackLiveActivityLifecycle()
    private var snapshot: Snapshot?
    private var lastPublishedSignature: PublishedSignature?
    private var operationGeneration: UInt64 = 0
    private var arbitrationLease: LiveActivityArbitrationLease?

    public init(settingsStore: SettingsStore) {
        self.settingsStore = settingsStore
        reconcileAfterLaunch()
    }

    public func settingDidChange() {
        guard let snapshot else {
            endPlaybackActivity(clearSnapshot: true)
            return
        }
        publish(snapshot, force: true)
    }

    public func update(
        video: Video,
        isPlaying: Bool,
        elapsed: TimeInterval,
        duration: TimeInterval,
        transcriptLine: String?,
        force: Bool = false
    ) {
        let snapshot = Snapshot(
            video: video,
            isPlaying: isPlaying,
            elapsed: elapsed.isFinite ? max(0, elapsed) : 0,
            duration: duration.isFinite ? max(0, duration) : 0,
            transcriptLine: transcriptLine
        )
        self.snapshot = snapshot
        publish(snapshot, force: force)
    }

    public func stop() {
        endPlaybackActivity(clearSnapshot: true)
    }

    private func endPlaybackActivity(clearSnapshot: Bool) {
        if clearSnapshot {
            snapshot = nil
        }
        lastPublishedSignature = nil
        let action = lifecycle.reconcile(mode: .off, videoID: nil)
        let lease = arbitrationLease
        arbitrationLease = nil
        guard action == .end
                || !Activity<PlaybackActivityAttributes>.activities.isEmpty
                || lease != nil else { return }
        operationGeneration &+= 1
        let generation = operationGeneration
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard generation == self.operationGeneration else {
                if let lease {
                    await LiveActivityArbitrationCenter.shared.releasePlayback(lease)
                }
                return
            }
            await self.endAll()
            if let lease {
                await LiveActivityArbitrationCenter.shared.releasePlayback(lease)
            }
        }
    }

    private func reconcileAfterLaunch() {
        lifecycle.reset()
        arbitrationLease = nil
        operationGeneration &+= 1
        let generation = operationGeneration
        Task { @MainActor [weak self] in
            guard let self, generation == self.operationGeneration else { return }
            await LiveActivityArbitrationCenter.shared.resetAfterLaunch()
            await self.endAll()
        }
    }

    private func publish(_ snapshot: Snapshot, force: Bool) {
        let selectedMode = settingsStore.settings.dynamicIslandMode
        guard PlaybackLockScreenPolicy.usesPlaybackLiveActivity(for: selectedMode) else {
            // Keep the current snapshot so changing from Off to an experimental
            // mode can present immediately without restarting playback.
            endPlaybackActivity(clearSnapshot: false)
            return
        }
        guard let presentation = PlaybackLiveActivityPolicy.presentation(
            for: selectedMode,
            transcriptLine: snapshot.transcriptLine,
            duration: snapshot.duration
        ) else {
            // Defensive fallback for future modes that resolve to no surface.
            endPlaybackActivity(clearSnapshot: false)
            return
        }

        let line = PlaybackLiveActivityPolicy.displayLine(
            transcriptLine: snapshot.transcriptLine,
            title: snapshot.video.title,
            author: snapshot.video.channelTitle
        )
        let signature = PublishedSignature(
            videoID: snapshot.video.id,
            presentation: presentation,
            isPlaying: snapshot.isPlaying,
            line: line,
            timeBucket: Int(snapshot.elapsed / 15)
        )
        let action = lifecycle.reconcile(mode: selectedMode, videoID: snapshot.video.id)
        if action == .update, !force, signature == lastPublishedSignature { return }
        lastPublishedSignature = signature

        let state = PlaybackActivityAttributes.ContentState(
            presentation: presentation,
            isPlaying: snapshot.isPlaying,
            elapsed: snapshot.elapsed,
            duration: snapshot.duration,
            line: line,
            waveformLevels: PlaybackLiveActivityPolicy.waveformLevels(
                videoID: snapshot.video.id,
                elapsed: snapshot.elapsed
            ),
            updatedAt: Date()
        )
        operationGeneration &+= 1
        let generation = operationGeneration
        Task { @MainActor [weak self] in
            guard let self, generation == self.operationGeneration else { return }
            let lease: LiveActivityArbitrationLease
            if action == .update, let currentLease = self.arbitrationLease {
                lease = currentLease
            } else {
                lease = await LiveActivityArbitrationCenter.shared.claimPlayback(
                    itemID: snapshot.video.id
                )
            }
            guard generation == self.operationGeneration else {
                await LiveActivityArbitrationCenter.shared.releasePlayback(lease)
                return
            }
            self.arbitrationLease = lease
            switch action {
            case .none, .end:
                await self.endAll()
            case .request, .replace:
                await self.endAll()
                guard generation == self.operationGeneration else { return }
                self.request(snapshot: snapshot, state: state)
            case .update:
                let activities = Activity<PlaybackActivityAttributes>.activities
                let updated = await Self.sendUpdate(
                    activities,
                    videoID: snapshot.video.id,
                    state: state
                )
                if !updated {
                    self.request(snapshot: snapshot, state: state)
                }
            }
        }
    }

    private func request(snapshot: Snapshot, state: PlaybackActivityAttributes.ContentState) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            playbackActivityLog.notice("Playback Live Activities are disabled by the system")
            lifecycle.reset()
            return
        }
        do {
            _ = try Activity.request(
                attributes: PlaybackActivityAttributes(
                    videoID: snapshot.video.id,
                    title: snapshot.video.title.isEmpty ? "AxrTube" : snapshot.video.title,
                    author: snapshot.video.channelTitle
                ),
                content: content(for: state),
                pushType: nil
            )
        } catch {
            lifecycle.reset()
            playbackActivityLog.error("Playback Live Activity request failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func content(for state: PlaybackActivityAttributes.ContentState) -> ActivityContent<PlaybackActivityAttributes.ContentState> {
        ActivityContent(
            state: state,
            staleDate: state.isPlaying ? Date().addingTimeInterval(90) : nil,
            relevanceScore: state.isPlaying ? 1 : 0.5
        )
    }

    private func endAll() async {
        let activities = Activity<PlaybackActivityAttributes>.activities
        let activityCount = activities.count
        await Self.sendEnds(activities)
        if activityCount > 1 {
            playbackActivityLog.notice("Removed \(activityCount, privacy: .public) duplicate playback activities")
        }
    }

    nonisolated private static func sendUpdate(
        _ activities: sending [Activity<PlaybackActivityAttributes>],
        videoID: String,
        state: PlaybackActivityAttributes.ContentState
    ) async -> Bool {
        guard let activity = activities.first(where: { $0.attributes.videoID == videoID }) else {
            return false
        }
        for duplicate in activities where duplicate.id != activity.id {
            await duplicate.end(nil, dismissalPolicy: .immediate)
        }
        await activity.update(ActivityContent(
            state: state,
            staleDate: state.isPlaying ? Date().addingTimeInterval(90) : nil,
            relevanceScore: state.isPlaying ? 1 : 0.5
        ))
        return true
    }

    nonisolated private static func sendEnds(
        _ activities: sending [Activity<PlaybackActivityAttributes>]
    ) async {
        for activity in activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }
}
#endif
