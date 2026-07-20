import Foundation
import Testing
@testable import iPocketTubeCore

// MARK: - QPB Phase 3 Regression Tests
//
// Each test that covers an open bug is marked `withKnownIssue` — it documents a confirmed bug.
// When the fix lands, remove the `withKnownIssue` wrapper and the test becomes a permanent guard.
//
// BUG IDs correspond to quality/BUGS.md entries.

// MARK: - Helpers

/// Wraps a videoRenderer dict in the minimal JSON structure expected by parseVideoGroupForTesting.
private func makeVideoRendererResponse(_ renderer: [String: Any]) -> [String: Any] {
    [
        "contents": [
            "sectionListRenderer": [
                "contents": [
                    [
                        "itemSectionRenderer": [
                            "contents": [["videoRenderer": renderer]]
                        ]
                    ]
                ]
            ]
        ]
    ]
}

/// Wraps a tileRenderer dict in the TVHTML5 sectionListRenderer structure.
private func makeTileRendererResponse(_ tile: [String: Any]) -> [String: Any] {
    [
        "contents": [
            "sectionListRenderer": [
                "contents": [
                    [
                        "itemSectionRenderer": [
                            "contents": [["tileRenderer": tile]]
                        ]
                    ]
                ]
            ]
        ]
    ]
}

/// Wraps a reelItemRenderer dict in the correct reelShelfRenderer structure
/// that the video group walker recognises.
private func makeReelItemResponse(_ reel: [String: Any]) -> [String: Any] {
    [
        "contents": [
            "reelShelfRenderer": [
                "items": [["reelItemRenderer": reel]]  // must be wrapped in reelItemRenderer key
            ]
        ]
    ]
}

// MARK: - BUG-001: extractNumber K/M/B suffix

@Suite("QPB Phase 3 Regressions — InnerTubeAPI+TextHelpers")
struct BUG001ExtractNumberKSuffixTests {

    @Test("BUG-001 1.5K views → 1500")
    func extractNumber_1500K_returns1500() async throws {
        let response = makeVideoRendererResponse([
            "videoId": "testid",
            "title": ["simpleText": "Test Title"],
            "ownerText": ["runs": [["text": "Channel", "navigationEndpoint": ["browseEndpoint": ["browseId": "UCtest"]]]]],
            "viewCountText": ["simpleText": "1.5K views"],
            "thumbnail": ["thumbnails": [["url": "https://i.ytimg.com/vi/testid/hqdefault.jpg"]]],
        ])
        let api = InnerTubeAPI()
        let group = try await api.parseVideoGroupForTesting(response, title: nil)
        let video = try #require(group.videos.first)
        #expect(video.viewCount == 1500, "1.5K views should parse to 1500")
    }

    @Test("BUG-001 2.3M views → 2300000")
    func extractNumber_2300000M_returns2300000() async throws {
        let response = makeVideoRendererResponse([
            "videoId": "testid2",
            "title": ["simpleText": "Test Title"],
            "ownerText": ["runs": [["text": "Channel", "navigationEndpoint": ["browseEndpoint": ["browseId": "UCtest2"]]]]],
            "viewCountText": ["simpleText": "2.3M views"],
            "thumbnail": ["thumbnails": [["url": "https://i.ytimg.com/vi/testid2/hqdefault.jpg"]]],
        ])
        let api = InnerTubeAPI()
        let group = try await api.parseVideoGroupForTesting(response, title: nil)
        let video = try #require(group.videos.first)
        #expect(video.viewCount == 2_300_000, "2.3M views should parse to 2300000")
    }

    @Test("BUG-001 plain integers still work after fix")
    func extractNumber_plainInt_returnsCorrectly() async throws {
        let response = makeVideoRendererResponse([
            "videoId": "testid3",
            "title": ["simpleText": "Test Title"],
            "ownerText": ["runs": [["text": "Channel", "navigationEndpoint": ["browseEndpoint": ["browseId": "UCtest3"]]]]],
            "viewCountText": ["simpleText": "1,234 views"],
            "thumbnail": ["thumbnails": [["url": "https://i.ytimg.com/vi/testid3/hqdefault.jpg"]]],
        ])
        let api = InnerTubeAPI()
        let group = try await api.parseVideoGroupForTesting(response, title: nil)
        let video = try #require(group.videos.first)
        #expect(video.viewCount == 1234)
    }
}

// MARK: - BUG-011: parseLockupViewModel/parseTileRenderer/parseReelItemRenderer viewCount: nil

@Suite("QPB Phase 3 Regressions — VideoRenderers parsers")
struct BUG011ViewCountParserTests {

    @Test("BUG-011 parseTileRenderer extracts viewCount from metadata lines")
    func parseTileRenderer_viewCountInMetadataLines_extractsViewCount() async throws {
        // tileRenderer: viewCount is embedded in the second metadata line
        let tile: [String: Any] = [
            "contentType": "TILE_CONTENT_TYPE_VIDEO",
            "onSelectCommand": ["watchEndpoint": ["videoId": "tilevidid"]],
            "metadata": [
                "tileMetadataRenderer": [
                    "title": ["simpleText": "Test Video"],
                    "lines": [
                        ["lineRenderer": ["items": [["lineItemRenderer": ["text": ["simpleText": "Channel"]]]]]],
                        ["lineRenderer": ["items": [["lineItemRenderer": ["text": ["simpleText": "1.2K views"]]]]]],
                    ]
                ]
            ],
            "header": [
                "tileHeaderRenderer": [
                    "thumbnail": ["thumbnails": [["url": "https://i.ytimg.com/vi/tilevidid/mqdefault.jpg"]]]
                ]
            ],
        ]
        let response = makeTileRendererResponse(tile)
        let api = InnerTubeAPI()
        let group = try await api.parseVideoGroupForTesting(response, title: nil)
        let video = group.videos.first
        #expect(video?.viewCount != nil, "tileRenderer should extract viewCount from metadata lines")
        #expect(video?.viewCount == 1200)
    }

    @Test("BUG-011 parseReelItemRenderer extracts viewCount from viewCountText")
    func parseReelItemRenderer_viewCountTextPresent_extractsViewCount() async throws {
        let reel: [String: Any] = [
            "videoId": "shortsvid",
            "headline": ["simpleText": "Shorts Title"],
            "viewCountText": ["runs": [["text": "1.5K"], ["text": " views"]]],
            "thumbnail": ["thumbnails": [["url": "https://i.ytimg.com/vi/shortsvid/hqdefault.jpg"]]],
            "navigationEndpoint": ["reelWatchEndpoint": ["videoId": "shortsvid"]],
        ]
        let response = makeReelItemResponse(reel)
        let api = InnerTubeAPI()
        let group = try await api.parseVideoGroupForTesting(response, title: nil)
        let video = group.videos.first
        #expect(video?.viewCount != nil, "reelItemRenderer should extract viewCount from viewCountText")
        #expect(video?.viewCount == 1500)
    }
}

// MARK: - BUG-014: shortViewCountText fallback missing

@Suite("QPB Phase 3 Regressions — VideoRenderers shortViewCountText")
struct BUG014ShortViewCountTextTests {

    @Test("BUG-014 parseVideoRenderer falls back to shortViewCountText when viewCountText absent")
    func parseVideoRenderer_shortViewCountTextFallback_extractsViewCount() async throws {
        // Renderer with shortViewCountText but no viewCountText
        let response = makeVideoRendererResponse([
            "videoId": "vidshort",
            "title": ["simpleText": "Video Title"],
            "ownerText": ["runs": [["text": "Channel", "navigationEndpoint": ["browseEndpoint": ["browseId": "UCshort"]]]]],
            "shortViewCountText": ["simpleText": "1.2K"],
            // viewCountText intentionally absent
            "thumbnail": ["thumbnails": [["url": "https://i.ytimg.com/vi/vidshort/hqdefault.jpg"]]],
        ])
        let api = InnerTubeAPI()
        let group = try await api.parseVideoGroupForTesting(response, title: nil)
        let video = group.videos.first
        #expect(video?.viewCount != nil, "Should fall back to shortViewCountText when viewCountText absent")
        #expect(video?.viewCount == 1200)
    }
}

// MARK: - BUG-013: evictAuthSensitiveData does not clear VideoDiskCache

@Suite("QPB Phase 3 Regressions — VideoPreloadCache auth eviction")
struct BUG013DiskCacheEvictionTests {

    @Test("BUG-013 VideoDiskCache.removeAll clears all stored entries")
    func diskCacheRemoveAll_clearsAllEntries() {
        // Use a dedicated temp directory so this test doesn't interfere with any shared cache.
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bug013-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let diskCache = VideoDiskCache(cacheDir: tempDir)
        let nextInfo = NextInfo(relatedVideos: [], likeStatus: .like, chapters: [])
        diskCache.store(nextInfo, videoId: "auth-test-vid", dataType: "nextInfo")

        // removeAll uses queue.sync internally — by the time it returns, the write from
        // store() (dispatched earlier to the same serial queue) has completed AND all files
        // have been deleted. load() will find nothing.
        diskCache.removeAll()

        let loadedBack = diskCache.load(NextInfo.self, videoId: "auth-test-vid", dataType: "nextInfo")
        #expect(loadedBack == nil,
                "After removeAll(), nextInfo should not be readable from disk")
    }
}

