import Foundation
import Testing
@testable import iPocketTubeCore

@Suite("Stream cache: playlists and policy")
struct StreamCachePolicyTests {
    static let base = URL(string: "https://manifest.example/api/manifest/hls_variant/id/x/file/index.m3u8")!
    static let master = """
    #EXTM3U
    #EXT-X-MEDIA:URI="https://m.example/hls_playlist/itag/140/a.m3u8",TYPE=AUDIO,GROUP-ID="140",NAME="Default",DEFAULT=YES
    #EXT-X-STREAM-INF:BANDWIDTH=900000,CODECS="avc1.4d401e,mp4a.40.2",RESOLUTION=640x360,AUDIO="140"
    https://m.example/hls_playlist/itag/134/v.m3u8
    #EXT-X-STREAM-INF:BANDWIDTH=2500000,CODECS="avc1.4d401f,mp4a.40.2",RESOLUTION=1280x720,AUDIO="140"
    https://m.example/hls_playlist/itag/136/v.m3u8
    #EXT-X-STREAM-INF:BANDWIDTH=2600000,CODECS="avc1.4d401f,mp4a.40.2",RESOLUTION=1280x720,AUDIO="140",YT-EXT-AUDIO-CONTENT-ID="en.2"
    https://m.example/hls_playlist/itag/136/dub.m3u8
    """

    @Test func attributesKeepQuotedCommas() {
        let a = HLSPlaylistText.attributes(of: #"#X:CODECS="avc1,mp4a",BANDWIDTH=5"#)
        #expect(a["CODECS"] == "avc1,mp4a")
        #expect(a["BANDWIDTH"] == "5")
    }

    @Test func picksOriginalLanguageWithinBudgetAndHeight() {
        let all = HLSPlaylistText.variants(in: Self.master, base: Self.base)
        #expect(all.count == 3)
        let big = HLSPlaylistText.selectVariant(all, maxHeight: 1080, bandwidthBudget: nil)
        #expect(big?.height == 720 && big?.audioContentID == nil)
        #expect(HLSPlaylistText.selectVariant(all, maxHeight: 1080, bandwidthBudget: 1_000_000)?.height == 360)
        #expect(HLSPlaylistText.selectVariant(all, maxHeight: 480, bandwidthBudget: nil)?.height == 360)
        #expect(HLSPlaylistText.selectVariant(all, maxHeight: 1080, bandwidthBudget: 10)?.height == 360)
    }

    @Test func masterRewriteKeepsOneVariantAndAudio() {
        let all = HLSPlaylistText.variants(in: Self.master, base: Self.base)
        let keep = HLSPlaylistText.selectVariant(all, maxHeight: 360, bandwidthBudget: nil)!
        let out = HLSPlaylistText.rewriteMaster(Self.master, base: Self.base, keep: keep) { "/p/" + HLSPlaylistText.renditionKey(for: $0) }
        #expect(out.components(separatedBy: "#EXT-X-STREAM-INF").count == 2)
        #expect(out.contains(#"URI="/p/itag140""#))
        #expect(out.contains("/p/itag134"))
        #expect(!out.contains("https://"))
    }

    @Test func mediaRewriteNumbersSegmentsAndMap() {
        let text = """
        #EXTM3U
        #EXT-X-MAP:URI="init.mp4"
        #EXTINF:5.0,
        s/0.ts
        #EXTINF:4.5,
        https://cdn.example/s/1.ts
        #EXT-X-ENDLIST
        """
        let info = HLSPlaylistText.mediaPlaylist(text, base: Self.base)
        #expect(info.segments.count == 2 && info.isComplete)
        #expect(info.segmentDurations == [5.0, 4.5])
        #expect(info.mapURL?.lastPathComponent == "init.mp4")
        let out = HLSPlaylistText.rewriteMedia(text, base: Self.base, segmentURI: { "/seg/\($0)" }, rewrite: { _ in "/x/1" })
        #expect(out.contains("/seg/0") && out.contains("/seg/1") && out.contains(#"URI="/x/1""#))
    }

    @Test func plannerGoesForwardFromPlayheadSkippingDone() {
        #expect(SegmentPrefetchPlanner.next(count: 10, cursor: 3, done: [3, 5], busy: [4], slots: 3) == [6, 7, 8])
        #expect(SegmentPrefetchPlanner.next(count: 3, cursor: 2, done: [2], busy: [], slots: 2) == [])
    }

    @Test func throughputBudgetLeavesHeadroom() {
        var e = ThroughputEstimate()
        #expect(e.variantBudget(parallelConnections: 3) == nil)
        e.record(bytes: 1_000_000, seconds: 8) // 1 Mbit/s per connection
        #expect(e.variantBudget(parallelConnections: 3) == 2_100_000)
        e.record(bytes: 10, seconds: 1)
        #expect(e.bitsPerSecond == 1_000_000)
    }

    @Test func cacheLimitKeepsPhoneFreeSpace() {
        let gb: Int64 = 1024 * 1024 * 1024
        #expect(StreamCachePolicy.limitBytes(availableCapacity: 50 * gb, current: 0) == 2 * gb)
        #expect(StreamCachePolicy.limitBytes(availableCapacity: 4 * gb, current: 0) == gb)
        #expect(StreamCachePolicy.limitBytes(availableCapacity: gb, current: 0) == 200 * 1024 * 1024)
    }

    @Test func byteRangeParsing() {
        #expect(LoopbackHTTPServer.byteRange("bytes=0-1", length: 10) == 0...1)
        #expect(LoopbackHTTPServer.byteRange("bytes=4-", length: 10) == 4...9)
        #expect(LoopbackHTTPServer.byteRange("bytes=-3", length: 10) == 7...9)
        #expect(LoopbackHTTPServer.byteRange("bytes=20-", length: 10) == nil)
    }
}

@Suite("Stream cache coverage for the progress bar")
struct StreamCacheCoverageTests {
    @Test func adjacentSegmentsMergeAndGapsSplit() {
        let r = StreamCacheCoverage.ranges(starts: [0, 5, 10, 15], durations: [5, 5, 5, 5], done: [0, 1, 3])
        #expect(r == [0...10, 15...20])
    }

    @Test func videoAndAudioIntersect() {
        let video: [ClosedRange<Double>] = [0...10, 15...20]
        let audio: [ClosedRange<Double>] = [0...6, 8...30]
        #expect(StreamCacheCoverage.intersect(video, audio) == [0...6, 8...10, 15...20])
    }
}
