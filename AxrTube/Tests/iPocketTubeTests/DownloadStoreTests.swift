import Testing
import Foundation
@testable import iPocketTubeCore

@Suite("Offline collection lifecycle")
@MainActor
struct DownloadStoreTests {
    @Test("Deleting playing media stops it before cancelling and removing files")
    func removalStopsPlaybackFirst() {
        for ids: Set<String> in [["playing"], ["playing", "other"]] {
            var events: [String] = []
            OfflineRemovalTransaction.perform(
                removingVideoIDs: ids, currentVideoID: "playing",
                stopPlayback: { events.append("stop") },
                cancelDownloads: { events.append("cancel") },
                removeFiles: { events.append("remove") }
            )
            #expect(events == ["stop", "cancel", "remove"])
        }
    }

    @Test("Deleting another video leaves unrelated playback running")
    func removalKeepsOtherPlayback() {
        var events: [String] = []
        OfflineRemovalTransaction.perform(
            removingVideoIDs: ["other"], currentVideoID: "playing",
            stopPlayback: { events.append("stop") },
            cancelDownloads: { events.append("cancel") },
            removeFiles: { events.append("remove") }
        )
        #expect(events == ["cancel", "remove"])
    }

    @Test("A stale unavailable source remains retryable after resolver replacement")
    func staleUnavailableSourceCanRetry() {
        #expect(OfflineFailurePresentationPolicy.allowsManualRetry(for: .unavailable))
        #expect(OfflineFailurePresentationPolicy.message(for: .unavailable).contains("Повторите"))
    }

    private func fixture(id: String = "offline-test") -> Video {
        Video(
            id: id,
            title: "Offline fixture",
            channelTitle: "iPocketTube Tests",
            duration: 42
        )
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("iPocketTube-DownloadStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("Video and audio use distinct deterministic containers")
    func mediaKindsUseDistinctDestinations() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = DownloadStore(baseDirectory: dir)
        let videoURL = store.destinationURL(for: "abc-123", kind: .video)
        let audioURL = store.destinationURL(for: "abc-123", kind: .audio)
        #expect(videoURL != audioURL)
        #expect(videoURL.pathExtension == "mp4")
        #expect(audioURL.pathExtension == "m4a")
        #expect(videoURL == store.destinationURL(for: "abc-123", kind: .video))
        #expect(store.destinationURL(
            for: "abc-123",
            kind: .video,
            fileExtension: ".movpkg"
        ).pathExtension == "movpkg")
    }

    @Test("Completed representation prevents a duplicate begin")
    func duplicatePrevention() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = DownloadStore(baseDirectory: dir)
        let video = fixture()
        let fileURL = store.destinationURL(for: video.id, kind: .audio)
        try Data(repeating: 0x11, count: 16).write(to: fileURL)
        store.complete(video: video, kind: .audio, fileURL: fileURL, fileSizeBytes: 16)

        #expect(store.containsCompleted(videoId: video.id, kind: .audio))
        #expect(store.begin(video: video, kind: .audio) == false)
        #expect(store.begin(video: video, kind: .video) == true)
    }

    @Test("Completed local media reopens without network metadata")
    func offlineReopen() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let video = fixture()
        let first = DownloadStore(baseDirectory: dir)
        let fileURL = first.destinationURL(for: video.id, kind: .video)
        try Data(repeating: 0x22, count: 32).write(to: fileURL)
        first.complete(video: video, kind: .video, fileURL: fileURL, fileSizeBytes: 32)

        let reopened = DownloadStore(baseDirectory: dir)
        let entry = reopened.entry(videoId: video.id, kind: .video)
        #expect(entry?.status == .completed)
        #expect(entry?.video.localFileURL == fileURL)
        #expect(entry?.video.localMediaKind == .video)
        #expect(entry?.fileSizeBytes == 32)
    }

    @Test("Relaunch promotes an atomically installed final file after a manifest crash window")
    func finalFileWinsManifestCrashWindow() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let video = fixture(id: "finalization-window")
        let first = DownloadStore(baseDirectory: dir)
        #expect(first.begin(video: video, kind: .audio))
        first.update(
            videoId: video.id,
            kind: .audio,
            status: .finalizationPending,
            progress: 1,
            fileSizeBytes: 48
        )
        let finalURL = first.destinationURL(for: video.id, kind: .audio)
        try Data(repeating: 0x77, count: 48).write(to: finalURL, options: .atomic)

        let reopened = DownloadStore(baseDirectory: dir)
        let entry = reopened.entry(videoId: video.id, kind: .audio)
        #expect(entry?.status == .completed)
        #expect(entry?.progress == 1)
        #expect(entry?.fileSizeBytes == 48)
        #expect(entry?.errorMessage == nil)
    }

    @Test("Interrupted download preserves progress and enters automatic reconciliation after relaunch")
    func interruptedDownloadBecomesAutomaticallyResumable() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let video = fixture()
        let first = DownloadStore(baseDirectory: dir)
        #expect(first.begin(video: video, kind: .video))
        first.update(videoId: video.id, kind: .video, status: .downloading, progress: 0.5)

        let reopened = DownloadStore(baseDirectory: dir)
        let entry = reopened.entry(videoId: video.id, kind: .video)
        #expect(reopened.isHydrated)
        #expect(entry?.status == .reconnecting)
        #expect(entry?.progress == 0.5)
        #expect(entry?.resumePolicy == .automatic)
        #expect(entry?.errorMessage?.contains("automatically") == true)
        #expect(reopened.automaticallyResumableEntries.map(\.id) == [entry?.id].compactMap { $0 })
    }

    @Test("Missing completed file remains visible as a recoverable failure")
    func missingCompletedFileIsNotSilentlyDropped() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let video = fixture()
        let first = DownloadStore(baseDirectory: dir)
        let fileURL = first.destinationURL(for: video.id, kind: .audio)
        try Data(repeating: 0x44, count: 24).write(to: fileURL)
        first.complete(video: video, kind: .audio, fileURL: fileURL, fileSizeBytes: 24)
        try FileManager.default.removeItem(at: fileURL)

        let reopened = DownloadStore(baseDirectory: dir)
        let entry = reopened.entry(videoId: video.id, kind: .audio)
        #expect(entry?.status == .failed)
        #expect(entry?.errorMessage?.contains("missing") == true)
        #expect(reopened.begin(video: video, kind: .audio))
        #expect(reopened.entries.filter { $0.videoId == video.id && $0.kind == .audio }.count == 1)
    }

    @Test("Failed audio entry can begin a clean retry without duplicating storage")
    func failedAudioCanRetry() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = DownloadStore(baseDirectory: dir)
        let video = fixture()

        #expect(store.begin(video: video, kind: .audio))
        store.update(
            videoId: video.id,
            kind: .audio,
            status: .failed,
            progress: 0,
            errorMessage: "Fixture failure"
        )

        #expect(store.begin(video: video, kind: .audio))
        #expect(store.entry(videoId: video.id, kind: .audio)?.status == .queued)
        #expect(store.entries.filter { $0.videoId == video.id && $0.kind == .audio }.count == 1)
    }

    @Test("First user tap claims an active reconciled job without losing progress")
    func userPlaybackClaimsActiveReconciliation() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = DownloadStore(baseDirectory: dir)
        let video = fixture(id: "active-claim")

        #expect(store.begin(video: video, kind: .audio))
        store.update(
            videoId: video.id,
            kind: .audio,
            status: .reconnecting,
            progress: 0.42,
            fileSizeBytes: 4_200,
            resumePolicy: .automatic
        )
        #expect(!store.begin(video: video, kind: .audio))
        #expect(store.claimForPlayback(video: video, kind: .audio))
        let claimed = store.entry(videoId: video.id, kind: .audio)
        #expect(claimed?.status == .queued)
        #expect(claimed?.progress == 0.42)
        #expect(claimed?.fileSizeBytes == 4_200)
        #expect(store.entries.filter { $0.videoId == video.id && $0.kind == .audio }.count == 1)
    }

    @Test("Verified partial bytes survive relaunch and count toward storage")
    func partialRangeManifestSurvivesRelaunch() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let video = fixture()
        let first = DownloadStore(baseDirectory: dir)
        #expect(first.begin(video: video, kind: .audio))
        first.update(videoId: video.id, kind: .audio, status: .downloading, progress: 0.02)

        try FileManager.default.createDirectory(
            at: first.partialDownloadsDirectory,
            withIntermediateDirectories: true
        )
        let part = first.partialDownloadsDirectory
            .appendingPathComponent("offline-test-audio-fixture.mp4.part")
        try Data(repeating: 0x55, count: 4_096).write(to: part)
        let index = SparseByteRangeIndex(ranges: [SparseByteRange(0, 4_096)])
        let sidecar = SparseCacheManifest(
            fingerprint: SparseSourceFingerprint(
                videoID: video.id,
                profile: "muxedMP4Extraction|fixture|mp4",
                mimeType: "video/mp4",
                contentLength: 16_384
            ),
            index: index,
            verifiedChunks: [VerifiedSparseChunk(
                range: SparseByteRange(0, 4_096),
                digest: "fixture"
            )],
            rangeSupported: true
        )
        let sidecarURL = first.partialDownloadsDirectory
            .appendingPathComponent("offline-test-audio-fixture.mp4.ranges.json")
        try JSONEncoder().encode(sidecar).write(to: sidecarURL, options: .atomic)

        let reopened = DownloadStore(baseDirectory: dir)
        let entry = reopened.entry(videoId: video.id, kind: .audio)
        #expect(entry?.status == .reconnecting)
        #expect(entry?.resumePolicy == .automatic)
        #expect(entry?.progress == 0.25)
        #expect(entry?.fileSizeBytes == 4_096)
        #expect(reopened.partialSizeBytes >= 4_096)
        #expect(reopened.totalSizeBytes >= 4_096)
        #expect(!reopened.canStore(
            additionalBytes: 1,
            limitBytes: reopened.totalSizeBytes
        ))
        // Legacy audio partials remain on disk for data preservation, but the
        // video-first runtime must never restart the removed audio pipeline.
        #expect(reopened.automaticallyResumableEntries.isEmpty)
    }

    @Test("Explicit user pause survives relaunch and is excluded from automatic reconciliation")
    func userPauseNeverAutoResumes() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let video = fixture()
        let first = DownloadStore(baseDirectory: dir)
        #expect(first.begin(video: video, kind: .audio))
        first.update(videoId: video.id, kind: .audio, status: .downloading, progress: 0.4)
        first.markUserPaused(videoId: video.id, kind: .audio)

        let reopened = DownloadStore(baseDirectory: dir)
        let entry = reopened.entry(videoId: video.id, kind: .audio)
        #expect(entry?.status == .paused)
        #expect(entry?.resumePolicy == .manual)
        #expect(reopened.automaticallyResumableEntries.isEmpty)

        #expect(reopened.begin(video: video, kind: .audio))
        #expect(reopened.entry(videoId: video.id, kind: .audio)?.resumePolicy == .automatic)
        #expect(reopened.entries.filter { $0.videoId == video.id && $0.kind == .audio }.count == 1)
    }

    @Test("Storage ceiling accounts for completed files")
    func storageLimit() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = DownloadStore(baseDirectory: dir)
        let video = fixture()
        let fileURL = store.destinationURL(for: video.id, kind: .video)
        try Data(repeating: 0x33, count: 64).write(to: fileURL)
        store.complete(video: video, kind: .video, fileURL: fileURL, fileSizeBytes: 64)

        #expect(store.totalSizeBytes == 64)
        #expect(store.canStore(additionalBytes: 35, limitBytes: 100))
        #expect(store.canStore(additionalBytes: 37, limitBytes: 100) == false)
    }

    @Test("Current item is pinned ahead of playback history")
    func currentItemIsFirst() {
        let older = historyEntry(id: "older", downloadedAt: Date(timeIntervalSince1970: 100), lastPlayedAt: Date(timeIntervalSince1970: 300))
        let current = historyEntry(id: "current", downloadedAt: Date(timeIntervalSince1970: 200), lastPlayedAt: nil)

        let sorted = DownloadHistorySortPolicy.sorted([older, current], currentItemID: current.id)

        #expect(sorted.map(\.id) == [current.id, older.id])
    }

    @Test("A then B keeps B first and A immediately behind it")
    func playbackHistoryDescending() {
        let neverPlayed = historyEntry(id: "never", downloadedAt: Date(timeIntervalSince1970: 500), lastPlayedAt: nil)
        let a = historyEntry(id: "a", downloadedAt: Date(timeIntervalSince1970: 100), lastPlayedAt: Date(timeIntervalSince1970: 300))
        let b = historyEntry(id: "b", downloadedAt: Date(timeIntervalSince1970: 200), lastPlayedAt: Date(timeIntervalSince1970: 400))

        let sorted = DownloadHistorySortPolicy.sorted([neverPlayed, a, b], currentItemID: b.id)

        #expect(sorted.map(\.id) == [b.id, a.id, neverPlayed.id])
    }

    @Test("Progress and pause updates do not rewrite last played time")
    func progressDoesNotChangeHistory() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = DownloadStore(baseDirectory: dir)
        let video = fixture()
        #expect(store.begin(video: video, kind: .audio))
        let activation = Date(timeIntervalSince1970: 1_700_000_000)
        store.markPlaybackActivated(videoId: video.id, kind: .audio, at: activation)
        store.update(videoId: video.id, kind: .audio, status: .downloading, progress: 0.4)
        store.markUserPaused(videoId: video.id, kind: .audio)

        #expect(store.entry(videoId: video.id, kind: .audio)?.lastPlayedAt == activation)
    }

    @Test("Never-played items use download time and deterministic ID ties")
    func neverPlayedOrderingAndTies() {
        let date = Date(timeIntervalSince1970: 500)
        let older = historyEntry(id: "older", downloadedAt: Date(timeIntervalSince1970: 100), lastPlayedAt: nil)
        let tieB = historyEntry(id: "b", downloadedAt: date, lastPlayedAt: nil)
        let tieA = historyEntry(id: "a", downloadedAt: date, lastPlayedAt: nil)

        let sorted = DownloadHistorySortPolicy.sorted([older, tieB, tieA], currentItemID: nil)

        #expect(sorted.map(\.videoId) == ["a", "b", "older"])
    }

    @Test("Incomplete jobs remain after playback history")
    func incompleteItemsRemainVisible() {
        var incomplete = historyEntry(id: "incomplete", downloadedAt: nil, lastPlayedAt: nil)
        incomplete.status = .reconnecting
        incomplete.progress = 0.4
        let played = historyEntry(id: "played", downloadedAt: Date(timeIntervalSince1970: 100), lastPlayedAt: Date(timeIntervalSince1970: 200))

        let sorted = DownloadHistorySortPolicy.sorted([incomplete, played], currentItemID: nil)

        #expect(sorted.map(\.videoId) == ["played", "incomplete"])
        #expect(sorted.last?.progress == 0.4)
    }

    @Test("Legacy completed item migrates a trustworthy file timestamp")
    func legacyTimestampMigration() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = DownloadStore(baseDirectory: dir)
        let video = fixture(id: "legacy")
        let fileURL = first.destinationURL(for: video.id, kind: .audio)
        try Data(repeating: 0x77, count: 12).write(to: fileURL)
        first.add(DownloadedVideo(
            videoId: video.id,
            title: video.title,
            channelTitle: video.channelTitle,
            thumbnailURL: nil,
            duration: 42,
            fileURL: fileURL,
            downloadedAt: nil,
            kind: .audio,
            status: .completed,
            fileSizeBytes: 12
        ))

        let reopened = DownloadStore(baseDirectory: dir)

        #expect(reopened.entry(videoId: video.id, kind: .audio)?.downloadedAt != nil)
    }

    @Test("Unknown timestamp has an honest display bucket")
    func unknownTimestampFallback() {
        #expect(DownloadTimestampPolicy.bucket(for: nil) == .unknown)
    }

    @Test("Completion timestamp is written once and survives later completion checks")
    func completionTimestampIsStable() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = DownloadStore(baseDirectory: dir)
        let video = fixture()
        let fileURL = store.destinationURL(for: video.id, kind: .audio)
        try Data(repeating: 0x66, count: 8).write(to: fileURL)
        store.complete(video: video, kind: .audio, fileURL: fileURL, fileSizeBytes: 8)
        let firstDate = store.entry(videoId: video.id, kind: .audio)?.downloadedAt
        store.complete(video: video, kind: .audio, fileURL: fileURL, fileSizeBytes: 8)

        #expect(firstDate != nil)
        #expect(store.entry(videoId: video.id, kind: .audio)?.downloadedAt == firstDate)
    }

    private func historyEntry(
        id: String,
        downloadedAt: Date?,
        lastPlayedAt: Date?
    ) -> DownloadedVideo {
        DownloadedVideo(
            videoId: id,
            title: id,
            channelTitle: "Channel",
            thumbnailURL: nil,
            duration: 60,
            fileURL: URL(fileURLWithPath: "/tmp/\(id).m4a"),
            downloadedAt: downloadedAt,
            lastPlayedAt: lastPlayedAt,
            kind: .audio,
            status: .completed,
            fileSizeBytes: 1
        )
    }
}
