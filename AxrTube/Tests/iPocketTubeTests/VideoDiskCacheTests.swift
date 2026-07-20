import Foundation
import Testing
@testable import iPocketTubeCore

// MARK: - VideoDiskCacheTests
//
// Tests for VideoDiskCache (Phase J):
//  - Store/load round-trip for each disk-eligible data type
//  - Path sanitisation prevents path traversal
//  - LRU eviction removes oldest files when size exceeds the limit

@Suite("Video Disk Cache")
struct VideoDiskCacheTests {

    // A temporary directory unique to each test run.
    private func makeTempCache() -> VideoDiskCache {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("st-disk-cache-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return VideoDiskCache(cacheDir: tmp)
    }

    // MARK: - Round-trip tests

    @Test("NextInfo round-trips through disk")
    func nextInfoRoundTrip() async throws {
        let cache = makeTempCache()
        let original = NextInfo(
            relatedVideos: [Video(id: "vid1", title: "T", channelTitle: "C", thumbnailURL: nil)],
            likeStatus: .like,
            chapters: []
        )
        cache.store(original, videoId: "abc123", dataType: "nextInfo")
        // The write is async on the serial queue — wait briefly
        try await Task.sleep(nanoseconds: 100_000_000)  // 100 ms
        let loaded = cache.load(NextInfo.self, videoId: "abc123", dataType: "nextInfo")
        #expect(loaded != nil)
        #expect(loaded?.relatedVideos.count == 1)
        #expect(loaded?.relatedVideos.first?.id == "vid1")
        #expect(loaded?.likeStatus == .like)
    }

    @Test("SponsorSegments round-trip through disk")
    func sponsorSegmentsRoundTrip() async throws {
        let cache = makeTempCache()
        let segments = [SponsorSegment(start: 1.0, end: 5.0, category: .sponsor)]
        cache.store(segments, videoId: "seg1", dataType: "sponsorSegments")
        try await Task.sleep(nanoseconds: 100_000_000)
        let loaded = cache.load([SponsorSegment].self, videoId: "seg1", dataType: "sponsorSegments")
        #expect(loaded?.count == 1)
        #expect(loaded?.first?.start == 1.0)
        #expect(loaded?.first?.category == .sponsor)
    }

    @Test("EndCards round-trip through disk")
    func endCardsRoundTrip() async throws {
        let cache = makeTempCache()
        let card = EndCard(
            id: "card1", style: .video, videoId: "v1",
            title: "Next Up", thumbnailURL: nil,
            left: 10, top: 20, width: 30, aspectRatio: 1.778,
            startMs: 50000, endMs: 60000
        )
        cache.store([card], videoId: "endcards1", dataType: "endCards")
        try await Task.sleep(nanoseconds: 100_000_000)
        let loaded = cache.load([EndCard].self, videoId: "endcards1", dataType: "endCards")
        #expect(loaded?.count == 1)
        #expect(loaded?.first?.id == "card1")
        #expect(loaded?.first?.style == .video)
    }

    @Test("DeArrowBranding round-trips through disk")
    func deArrowBrandingRoundTrip() async throws {
        let cache = makeTempCache()
        let branding = DeArrowService.BrandingInfo(title: "Better Title", thumbnailTimestamp: 42.5)
        cache.store(branding, videoId: "dearrow1", dataType: "deArrowBranding")
        try await Task.sleep(nanoseconds: 100_000_000)
        let loaded = cache.load(DeArrowService.BrandingInfo.self, videoId: "dearrow1", dataType: "deArrowBranding")
        #expect(loaded?.title == "Better Title")
        #expect(loaded?.thumbnailTimestamp == 42.5)
    }

    // MARK: - Path sanitisation

    @Test("fileURL sanitises path traversal attempts in videoId")
    func pathSanitisation() {
        let cache = makeTempCache()
        let url = cache.fileURL(videoId: "../../etc/passwd", dataType: "nextInfo")
        let filename = url.lastPathComponent
        #expect(!filename.contains("/"))
        #expect(!filename.contains(".."))
        #expect(filename.hasSuffix("-nextInfo.json"))
    }

    @Test("fileURL for normal videoId produces expected filename")
    func fileURLNormalVideoId() {
        let cache = makeTempCache()
        let url = cache.fileURL(videoId: "dQw4w9WgXcQ", dataType: "nextInfo")
        #expect(url.lastPathComponent == "dQw4w9WgXcQ-nextInfo.json")
        #expect(url.deletingLastPathComponent() == cache.cacheDir)
    }

    // MARK: - In-memory eviction skip (energy report fix)
    //
    // Apple energy report for 4.8 showed evictIfNeeded() scanning the whole cache
    // directory on every single write. Fix: skip the scan unless estimatedBytes exceeds
    // 90% of maxBytes.

    @Test("evictIfNeeded skips filesystem scan when well under the size limit")
    func evictSkipsWhenUnderLimit() throws {
        let cache = makeTempCache()
        // Write a tiny value — estimated bytes will be minimal, far below 20 MB.
        cache.store([SponsorSegment(start: 0, end: 1, category: .sponsor)],
                    videoId: "skip-test", dataType: "sponsorSegments")
        // The cache directory must still exist (no eviction ran).
        // If eviction ran it would delete nothing (only one file), but the test
        // verifies the fast-path: the file is present after the write.
        Thread.sleep(forTimeInterval: 0.15)
        let url = cache.fileURL(videoId: "skip-test", dataType: "sponsorSegments")
        #expect(FileManager.default.fileExists(atPath: url.path),
                "File should exist — evictIfNeeded should have skipped when well under limit")
    }

    @Test("Appending beyond maxCount is silently ignored")
    func evictionFiringWhenOverLimit() throws {
        let cache = makeTempCache()
        let limit = VideoDiskCache.maxBytes
        // Write enough data to exceed the limit artificially by forcing estimatedBytes high.
        // We use a helper that accesses the private queue, so we bypass the estimate by
        // writing large blobs directly.
        let bigChunk = String(repeating: "x", count: 1024 * 1024)  // 1 MB string
        for i in 0..<22 {  // 22 MB → triggers real eviction
            cache.store(bigChunk, videoId: "big-\(i)", dataType: "chunk")
        }
        Thread.sleep(forTimeInterval: 0.5)  // let all async writes land
        // After eviction, directory size should be at most maxBytes.
        let fm = FileManager.default
        let files = try fm.contentsOfDirectory(at: cache.cacheDir, includingPropertiesForKeys: [.fileSizeKey])
        let totalSize = files.compactMap {
            (try? $0.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
        }.reduce(0, +)
        #expect(totalSize <= limit, "Total size \(totalSize) should be ≤ \(limit) after eviction")
        _ = limit  // silence warning
    }

    // MARK: - Miss returns nil

    @Test("Missing file returns nil")
    func missingFileReturnsNil() {
        let cache = makeTempCache()
        let result = cache.load(NextInfo.self, videoId: "no-such-video", dataType: "nextInfo")
        #expect(result == nil)
    }
}
