import Foundation
import Testing
@testable import SmartTubeIOSCore

@Suite("Instant audio sparse cache")
struct InstantAudioSparseCacheTests {
    private func format(_ mimeType: String) -> VideoFormat {
        VideoFormat(
            label: "fixture",
            width: mimeType.hasPrefix("video/") ? 640 : 0,
            height: mimeType.hasPrefix("video/") ? 360 : 0,
            fps: mimeType.hasPrefix("video/") ? 30 : 0,
            mimeType: mimeType,
            url: URL(string: "https://example.invalid/redacted")!,
            bitrate: 128_000
        )
    }

    @Test("Header and tail ranges can arrive before the middle")
    func tailRangeCanBePrioritized() {
        var index = SparseByteRangeIndex()
        index.insert(SparseByteRange(0, 2))
        index.insert(SparseByteRange(9_000, 10_000))

        #expect(index.contains(SparseByteRange(9_500, 10_000)))
        #expect(index.missingRanges(in: SparseByteRange(0, 10_000)) == [
            SparseByteRange(2, 9_000),
        ])
    }

    @Test("Adjacent and overlapping ranges merge into cache hits")
    func rangeMergeAvoidsDuplicateNetworkWork() {
        var index = SparseByteRangeIndex()
        index.insert(SparseByteRange(0, 512))
        index.insert(SparseByteRange(256, 1_024))
        index.insert(SparseByteRange(1_024, 2_048))

        #expect(index.ranges == [SparseByteRange(0, 2_048)])
        #expect(index.missingRanges(in: SparseByteRange(128, 1_900)).isEmpty)
        #expect(index.cachedByteCount == 2_048)
    }

    @Test("206 Content-Range and ignored-Range 200 map bytes safely")
    func interpretsPartialAndWholeResponses() {
        let partial = HTTPByteRangeInterpreter.placement(
            statusCode: 206,
            requested: SparseByteRange(1_000, 1_500),
            contentRange: "bytes 1000-1499/10000",
            contentLength: 500,
            bodyCount: 500
        )
        #expect(partial == HTTPByteRangePlacement(
            storedRange: SparseByteRange(1_000, 1_500),
            totalLength: 10_000,
            supportsByteRanges: true,
            serverReturnedWholeBody: false
        ))

        let whole = HTTPByteRangeInterpreter.placement(
            statusCode: 200,
            requested: SparseByteRange(5_000, 5_500),
            contentRange: nil,
            contentLength: 10_000,
            bodyCount: 10_000
        )
        #expect(whole == HTTPByteRangePlacement(
            storedRange: SparseByteRange(0, 10_000),
            totalLength: 10_000,
            supportsByteRanges: false,
            serverReturnedWholeBody: true
        ))
    }

    @Test("Mismatched Content-Range and byte counts are rejected")
    func rejectsCorruptRangePlacement() {
        #expect(HTTPByteRangeInterpreter.placement(
            statusCode: 206,
            requested: SparseByteRange(1_000, 1_500),
            contentRange: "bytes 1000-1499/10000",
            contentLength: 500,
            bodyCount: 499
        ) == nil)
        #expect(HTTPByteRangeInterpreter.placement(
            statusCode: 206,
            requested: SparseByteRange(1_000, 1_500),
            contentRange: "bytes 900-1399/10000",
            contentLength: 500,
            bodyCount: 500
        ) == nil)
        #expect(HTTPByteRangeInterpreter.placement(
            statusCode: 200,
            requested: SparseByteRange(1_000, 1_500),
            contentRange: nil,
            contentLength: 10_000,
            bodyCount: 500
        ) == nil)
    }

    @Test("Overlapping requests coalesce and cancellation releases reservation")
    func requestCoalescingAndCancellation() {
        let cache = SparseByteRangeIndex(ranges: [SparseByteRange(0, 100)])
        var requests = SparseByteRangeRequestSet()

        let firstReserved = requests.reserve(SparseByteRange(100, 500), cached: cache)
        let overlapReserved = requests.reserve(SparseByteRange(300, 700), cached: cache)
        let cachedReserved = requests.reserve(SparseByteRange(0, 50), cached: cache)
        #expect(firstReserved)
        #expect(!overlapReserved)
        #expect(!cachedReserved)
        requests.remove(SparseByteRange(100, 500))
        let reservedAfterCancellation = requests.reserve(SparseByteRange(300, 700), cached: cache)
        #expect(reservedAfterCancellation)
    }

    @Test("Refreshing a stale signed URL does not invalidate cached ranges")
    func staleURLRefreshPreservesSparseCache() {
        let before = SparseByteRangeIndex(ranges: [
            SparseByteRange(0, 1_024),
            SparseByteRange(9_000, 10_000),
        ])
        var after = before
        after.insert(SparseByteRange(1_024, 2_048))

        #expect(after.contains(SparseByteRange(0, 2_048)))
        #expect(after.contains(SparseByteRange(9_000, 10_000)))
        #expect(after.cachedByteCount == before.cachedByteCount + 1_024)
    }

    @Test("Refreshed URL may resume only the same representation")
    func fingerprintCompatibility() {
        let original = SparseSourceFingerprint(
            videoID: "video-a",
            profile: "directM4A|128000|m4a",
            mimeType: "audio/mp4",
            contentLength: 10_000,
            entityTag: "etag-a"
        )
        #expect(original.isCompatible(with: SparseSourceFingerprint(
            videoID: "video-a",
            profile: "directM4A|128000|m4a",
            mimeType: "audio/mp4",
            contentLength: 10_000,
            entityTag: "etag-a"
        )))
        #expect(!original.isCompatible(with: SparseSourceFingerprint(
            videoID: "video-a",
            profile: "directM4A|256000|m4a",
            mimeType: "audio/mp4",
            contentLength: 10_000
        )))
    }

    @Test("A to B to A ignores the first A callback")
    func commandGenerationRejectsLateCallback() {
        var gate = PlaybackCommandGate()
        let firstA = gate.advance()
        _ = gate.advance()
        let secondA = gate.advance()
        #expect(!gate.isCurrent(firstA))
        #expect(gate.isCurrent(secondA))
    }

    @Test("Lock lifecycle is not classified as a stall")
    func lockDoesNotRunStallRecovery() {
        #expect(PlaybackLifecyclePolicy.shouldRunStallRecovery(
            scene: .active,
            hasTrueAudioInterruption: false,
            isReplacingItem: false
        ))
        #expect(!PlaybackLifecyclePolicy.shouldRunStallRecovery(
            scene: .inactive,
            hasTrueAudioInterruption: false,
            isReplacingItem: false
        ))
        #expect(!PlaybackLifecyclePolicy.shouldRunStallRecovery(
            scene: .background,
            hasTrueAudioInterruption: false,
            isReplacingItem: false
        ))
    }

    @Test("Cold start selects a completed local file before network resolution")
    func coldStartLocalPrecedesNetwork() {
        #expect(AudioFirstColdStartPolicy.decide(
            manifestReady: true,
            hasReadableCompletedLocalFile: true,
            hasPartialRanges: false
        ) == .playCompletedLocal)
        #expect(AudioFirstColdStartPolicy.decide(
            manifestReady: true,
            hasReadableCompletedLocalFile: false,
            hasPartialRanges: true
        ) == .resumePartialCache)
    }

    @Test("Transient failures back off while permanent failures stop")
    func retryClassification() {
        #expect(SparseDownloadRetryPolicy.classify(
            urlErrorCode: NSURLErrorNetworkConnectionLost,
            httpStatus: nil
        ) == .transient)
        #expect(SparseDownloadRetryPolicy.classify(urlErrorCode: nil, httpStatus: 503) == .transient)
        #expect(SparseDownloadRetryPolicy.classify(urlErrorCode: nil, httpStatus: 403) == .staleSource)
        #expect(SparseDownloadRetryPolicy.classify(urlErrorCode: nil, httpStatus: 415) == .unsupported)
        #expect(SparseDownloadRetryPolicy.delayMilliseconds(attempt: 4, seed: 7) >
            SparseDownloadRetryPolicy.delayMilliseconds(attempt: 1, seed: 7))
        #expect(SparseDownloadRetryPolicy.shouldRetry(failure: .transient, attempt: 4))
        #expect(SparseDownloadRetryPolicy.shouldRetry(failure: .staleSource, attempt: 4))
        #expect(!SparseDownloadRetryPolicy.shouldRetry(failure: .transient, attempt: 5))
        #expect(!SparseDownloadRetryPolicy.shouldRetry(failure: .corruptRange, attempt: 0))
    }

    @Test("Connection loss preserves verified chunks across manifest round-trip")
    func connectionLossPreservesDurableMissingRanges() throws {
        let fingerprint = SparseSourceFingerprint(
            videoID: "resume-fixture",
            profile: "directM4A|128000|m4a",
            mimeType: "audio/mp4",
            contentLength: 8_192,
            entityTag: "same-validator"
        )
        let index = SparseByteRangeIndex(ranges: [
            SparseByteRange(0, 2_048),
            SparseByteRange(6_144, 8_192),
        ])
        let manifest = SparseCacheManifest(
            fingerprint: fingerprint,
            index: index,
            verifiedChunks: [
                VerifiedSparseChunk(range: SparseByteRange(0, 2_048), digest: "head"),
                VerifiedSparseChunk(range: SparseByteRange(6_144, 8_192), digest: "tail"),
            ],
            rangeSupported: true,
            retryCount: 2
        )
        let restored = try JSONDecoder().decode(
            SparseCacheManifest.self,
            from: JSONEncoder().encode(manifest)
        )

        #expect(restored.index.cachedByteCount == 4_096)
        #expect(restored.index.missingRanges(in: SparseByteRange(0, 8_192)) == [
            SparseByteRange(2_048, 6_144),
        ])
        #expect(restored.fingerprint == fingerprint)
    }

    @Test("Restored cache requires matching validator probe and rejects whole-body 200")
    func restoredCacheValidatorIsStrict() {
        let cached = SparseSourceFingerprint(
            videoID: "validator-fixture",
            profile: "muxedMP4Extraction|348094|mp4",
            mimeType: "video/mp4",
            contentLength: 10_000,
            entityTag: "etag-a"
        )
        let same = SparseSourceFingerprint(
            videoID: "validator-fixture",
            profile: "muxedMP4Extraction|348094|mp4",
            mimeType: "video/mp4",
            contentLength: 10_000,
            entityTag: "etag-a"
        )
        let changed = SparseSourceFingerprint(
            videoID: "validator-fixture",
            profile: "muxedMP4Extraction|999999|mp4",
            mimeType: "video/mp4",
            contentLength: 10_000,
            entityTag: "etag-b"
        )

        #expect(SparseRestoredCacheValidator.accepts(
            cachedProbe: Data([0, 1]),
            responseProbe: Data([0, 1]),
            serverReturnedWholeBody: false,
            cachedFingerprint: cached,
            responseFingerprint: same
        ))
        #expect(!SparseRestoredCacheValidator.accepts(
            cachedProbe: Data([0, 1]),
            responseProbe: Data([0, 1]),
            serverReturnedWholeBody: true,
            cachedFingerprint: cached,
            responseFingerprint: same
        ))
        #expect(!SparseRestoredCacheValidator.accepts(
            cachedProbe: Data([0, 1]),
            responseProbe: Data([0, 2]),
            serverReturnedWholeBody: false,
            cachedFingerprint: cached,
            responseFingerprint: changed
        ))
    }

    @Test("Partial cache seek is bounded by duration, not download percent")
    func partialSeekCanRequestMissingRange() {
        var state = ProgressiveAudioStateMachine()
        _ = state.receive(downloaded: 1_000, expected: 100_000)
        #expect(state.clampedSeekTime(90, duration: 100) == 90)
        #expect(state.clampedSeekTime(120, duration: 100) == 100)
    }

    @Test("Muxed MP4 starts through sparse playback before export")
    func muxedPlaybackPrecedesExport() {
        let plan = OfflineAudioDownloadPlan(
            source: .muxedMP4Extraction,
            format: format("video/mp4; codecs=\"avc1.42001E, mp4a.40.2\""),
            downloadFileExtension: "mp4"
        )
        #expect(OfflineAudioFormatSelector.supportsInstantPlayback(plan))
        #expect(OfflineAudioFormatSelector.requiresPostDownloadExport(plan))

        var milestones = InstantAudioMilestones()
        milestones.timelineAdvanced()
        #expect(milestones.timelineAdvancedBeforeDownloadCompleted)
        milestones.downloadCompleted()
        milestones.exportBegan()
        #expect(milestones.didBeginExport)
        #expect(!milestones.timelineAdvancedBeforeDownloadCompleted)
    }

    @Test("Video regression: playable full sparse cache survives finalizer and stale callbacks")
    func playableSparseStateIsAuthoritativeAcrossRelaunch() {
        var state = AudioFirstAuthoritativeState()
        let began = state.reduce(.begin(generation: 41, durableProgress: 1))
        let installed = state.reduce(.playbackInstalled(generation: 41))
        let advanced = state.reduce(.timeline(generation: 41, position: 59))
        let finalizing = state.reduce(.finalizationStarted(generation: 41))
        let failedFinalization = state.reduce(.finalizationFailed(generation: 41, message: "export failed"))
        #expect(began && installed && advanced && finalizing && failedFinalization)
        #expect(state.phase == .finalizationPending("export failed"))
        #expect(state.hasPlayableSource)
        #expect(state.downloadProgress == 1)
        #expect(state.playbackPosition == 59)

        // A late publisher from the prior command cannot roll the timeline back
        // or replace the live card with a terminal error.
        let relaunched = state.reduce(.begin(generation: 42, durableProgress: 1))
        let staleFailure = state.reduce(.exhaustedFailure(generation: 41, message: "stale"))
        let staleTimeline = state.reduce(.timeline(generation: 41, position: 47))
        let restored = state.reduce(.userSeek(generation: 42, position: 71))
        let reinstalled = state.reduce(.playbackInstalled(generation: 42))
        let preSeekZero = state.reduce(.timeline(generation: 42, position: 0))
        let landed = state.reduce(.timeline(generation: 42, position: 71.2))
        let retryFailure = state.reduce(.finalizationFailed(generation: 42, message: "retry locally"))
        #expect(relaunched && restored && reinstalled && landed && retryFailure)
        #expect(!staleFailure && !staleTimeline && !preSeekZero)
        #expect(state.phase == .finalizationPending("retry locally"))
        #expect(state.playbackPosition >= 71)
        #expect(state.downloadProgress == 1)
    }

    @Test("Only an explicit seek may move the authoritative timeline backwards")
    func timelineRejectsStaleRollbackButAcceptsSeek() {
        var state = AudioFirstAuthoritativeState()
        _ = state.reduce(.begin(generation: 8, durableProgress: 0.5))
        _ = state.reduce(.playbackInstalled(generation: 8))
        _ = state.reduce(.timeline(generation: 8, position: 60))
        _ = state.reduce(.timeline(generation: 8, position: 48))
        #expect(state.playbackPosition == 60)

        _ = state.reduce(.userSeek(generation: 8, position: 20))
        #expect(state.playbackPosition == 20)
        let staleAfterSeek = state.reduce(.timeline(generation: 8, position: 60.2))
        let landedAfterSeek = state.reduce(.timeline(generation: 8, position: 20.1))
        #expect(!staleAfterSeek)
        #expect(landedAfterSeek)
        #expect(state.playbackPosition < 21)
    }
}
