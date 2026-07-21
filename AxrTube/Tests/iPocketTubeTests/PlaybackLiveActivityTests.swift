import Foundation
import Testing
@testable import iPocketTubeCore

@Suite("Playback Live Activity contract")
struct PlaybackLiveActivityTests {
    @Test("Only explicit non-off modes opt into playback Live Activity")
    func lockScreenPolicyFollowsUserMode() {
        #expect(!PlaybackLockScreenPolicy.usesPlaybackLiveActivity(for: .off))
        for mode in PlaybackLiveActivityMode.allCases where mode != .off {
            #expect(PlaybackLockScreenPolicy.usesPlaybackLiveActivity(for: mode))
        }
    }

    @Test("Every user mode survives settings persistence", arguments: PlaybackLiveActivityMode.allCases)
    func modeRoundTrips(_ mode: PlaybackLiveActivityMode) throws {
        var settings = AppSettings()
        settings.dynamicIslandMode = mode

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)

        #expect(decoded.dynamicIslandMode == mode)
    }

    @Test("Legacy experiment modes converge on the single progress style")
    func legacyModesConvergeOnProgress() {
        #expect(PlaybackLiveActivityPolicy.presentation(for: .off, transcriptLine: "line", duration: 60) == nil)
        #expect(PlaybackLiveActivityPolicy.presentation(for: .minimal, transcriptLine: nil, duration: 0) == .progress)
        #expect(PlaybackLiveActivityPolicy.presentation(for: .progress, transcriptLine: nil, duration: 60) == .progress)
        #expect(PlaybackLiveActivityPolicy.presentation(for: .waveform, transcriptLine: nil, duration: 60) == .progress)
        #expect(PlaybackLiveActivityPolicy.presentation(for: .line, transcriptLine: nil, duration: 60) == .progress)
    }

    @Test("Legacy automatic mode also converges on progress")
    func automaticModeConvergesOnProgress() {
        #expect(PlaybackLiveActivityPolicy.presentation(for: .automatic, transcriptLine: "Caption", duration: 60) == .progress)
        #expect(PlaybackLiveActivityPolicy.presentation(for: .automatic, transcriptLine: "  ", duration: 60) == .progress)
        #expect(PlaybackLiveActivityPolicy.presentation(for: .automatic, transcriptLine: nil, duration: 0) == .progress)
    }

    @Test("Compact progress segments form one green and yellow timeline")
    func segmentedProgressFill() {
        #expect(abs(PlaybackLiveActivityPolicy.segmentFill(
            progress: 0.18,
            lowerBound: 0,
            upperBound: 0.36
        ) - 0.5) < 0.0001)
        #expect(PlaybackLiveActivityPolicy.segmentFill(
            progress: 0.18,
            lowerBound: 0.36,
            upperBound: 1
        ) == 0)
        #expect(PlaybackLiveActivityPolicy.segmentFill(
            progress: 0.68,
            lowerBound: 0,
            upperBound: 0.36
        ) == 1)
        #expect(abs(PlaybackLiveActivityPolicy.segmentFill(
            progress: 0.68,
            lowerBound: 0.36,
            upperBound: 1
        ) - 0.5) < 0.0001)
    }

    @Test("Line mode always has a safe nonempty fallback")
    func lineFallback() {
        #expect(PlaybackLiveActivityPolicy.displayLine(transcriptLine: " Caption ", title: "Title", author: "Author") == "Caption")
        #expect(PlaybackLiveActivityPolicy.displayLine(transcriptLine: nil, title: "Title", author: "Author") == "Title")
        #expect(PlaybackLiveActivityPolicy.displayLine(transcriptLine: nil, title: " ", author: "Author") == "Author")
        #expect(PlaybackLiveActivityPolicy.displayLine(transcriptLine: nil, title: "", author: "") == "AxrTube")
    }

    @Test("Lifecycle requests one activity and deduplicates same video updates")
    func lifecycleDeduplication() {
        var lifecycle = PlaybackLiveActivityLifecycle()
        #expect(lifecycle.reconcile(mode: .progress, videoID: "one") == .request)
        #expect(lifecycle.reconcile(mode: .progress, videoID: "one") == .update)
        #expect(lifecycle.reconcile(mode: .line, videoID: "one") == .update)
        #expect(lifecycle.reconcile(mode: .line, videoID: "two") == .replace)
        #expect(lifecycle.reconcile(mode: .off, videoID: "two") == .end)
        #expect(lifecycle.reconcile(mode: .off, videoID: nil) == .none)
        #expect(lifecycle.reconcile(mode: .waveform, videoID: "two") == .request)
    }

    @Test("Playback preempts the matching download presentation")
    func playbackPreemptsMatchingDownload() {
        var policy = LiveActivityArbitrationPolicy()
        let download = policy.beginDownload(itemID: "video")
        let playback = policy.claimPlayback(itemID: "video")

        #expect(download.shouldPresent)
        #expect(playback.preemptedDownload == download.lease)
        #expect(!policy.isDownloadPresented)
        #expect(policy.playbackLease == playback.lease)
    }

    @Test("Download-only presentation is allowed")
    func downloadOnlyIsAllowed() {
        var policy = LiveActivityArbitrationPolicy()
        let download = policy.beginDownload(itemID: "download-only")

        #expect(download.shouldPresent)
        #expect(download.preemptedDownload == nil)
        #expect(policy.downloadLease == download.lease)
        #expect(policy.playbackLease == nil)
    }

    @Test("Playback release restores an unfinished download exactly once")
    func playbackReleaseRestoresDownloadOnce() {
        var policy = LiveActivityArbitrationPolicy()
        let download = policy.beginDownload(itemID: "video")
        let playback = policy.claimPlayback(itemID: "video")

        #expect(policy.releasePlayback(playback.lease) == download.lease)
        #expect(policy.releasePlayback(playback.lease) == nil)
        #expect(policy.isDownloadPresented)
    }

    @Test("A stale playback release cannot steal a newer owner")
    func staleReleaseDoesNotStealNewPlayback() {
        var policy = LiveActivityArbitrationPolicy()
        let oldPlayback = policy.claimPlayback(itemID: "old")
        let newPlayback = policy.claimPlayback(itemID: "new")

        #expect(policy.releasePlayback(oldPlayback.lease) == nil)
        #expect(policy.playbackLease == newPlayback.lease)
    }

    @Test("Relaunch reset clears ownership and a replacement download stays deduplicated")
    func relaunchCleanupAndDeduplication() {
        var policy = LiveActivityArbitrationPolicy()
        let oldDownload = policy.beginDownload(itemID: "old")
        let currentDownload = policy.beginDownload(itemID: "current")
        let playback = policy.claimPlayback(itemID: "current")
        let pendingReplacement = policy.beginDownload(itemID: "pending-replacement")

        #expect(currentDownload.preemptedDownload == oldDownload.lease)
        #expect(!pendingReplacement.shouldPresent)
        #expect(pendingReplacement.preemptedDownload == currentDownload.lease)
        let reset = policy.resetAfterLaunch()
        #expect(reset.playback == playback.lease)
        #expect(reset.download == pendingReplacement.lease)
        #expect(policy.playbackLease == nil)
        #expect(policy.downloadLease == nil)

        let afterRelaunch = policy.beginDownload(itemID: "after-relaunch")
        #expect(afterRelaunch.shouldPresent)
        #expect(afterRelaunch.preemptedDownload == nil)
    }

    @Test("Playback mode Off leaves download-only presentation available")
    func playbackOffDoesNotSuppressDownload() {
        var policy = LiveActivityArbitrationPolicy()
        let playbackPresentation = PlaybackLiveActivityPolicy.presentation(
            for: .off,
            transcriptLine: nil,
            duration: 60
        )
        if playbackPresentation != nil {
            _ = policy.claimPlayback(itemID: "video")
        }

        let download = policy.beginDownload(itemID: "video")
        #expect(playbackPresentation == nil)
        #expect(download.shouldPresent)
        #expect(policy.playbackLease == nil)
    }
}
