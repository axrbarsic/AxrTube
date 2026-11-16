import Foundation
import os
import Testing
@testable import iPocketTubeCore

/// Fake googlevideo origin for the proxy's private URLSession.
final class FakeOrigin: URLProtocol {
    static let state = OSAllocatedUnfairLock(initialState: (files: [String: Data](), offline: false))

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let (files, offline) = Self.state.withLock { ($0.files, $0.offline) }
        guard !offline, let url = request.url, let data = files[url.absoluteString] else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let mime = url.pathExtension == "ts" ? "video/mp2t" : "application/vnd.apple.mpegurl"
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": mime])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

@Suite("Stream cache proxy end to end", .serialized)
struct StreamCacheProxyTests {
    private func get(_ url: URL) async throws -> (Data, Int) {
        let (data, response) = try await URLSession.shared.data(from: url)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    private func local(_ base: URL, _ path: String) -> URL {
        URL(string: "http://127.0.0.1:\(base.port!)\(path)")!
    }

    private func firstPath(in text: String, containing marker: String) -> String? {
        text.components(separatedBy: .newlines).compactMap { line -> String? in
            if let r = line.range(of: "URI=\""), line.contains(marker) {
                return String(line[r.upperBound...].prefix { $0 != "\"" })
            }
            return line.hasPrefix("/") && line.contains(marker) ? line : nil
        }.first
    }

    @Test func playsThroughProxyPrefetchesAndServesOffline() async throws {
        let v = "https://m.example/hls_playlist/itag/134/v.m3u8"
        let master = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=900000,CODECS="avc1.4d401e",RESOLUTION=640x360
        \(v)
        #EXT-X-STREAM-INF:BANDWIDTH=2500000,CODECS="avc1.4d401f",RESOLUTION=1280x720
        https://m.example/hls_playlist/itag/136/v.m3u8
        """
        var media = "#EXTM3U\n#EXT-X-TARGETDURATION:5\n"
        var files: [String: Data] = ["https://m.example/master.m3u8": Data(master.utf8)]
        for i in 0..<4 {
            let seg = "https://cdn.example/itag/134/sq/\(i)/seg.ts"
            media += "#EXTINF:5.0,\n\(seg)\n"
            files[seg] = Data(repeating: UInt8(i), count: 70_000)
        }
        media += "#EXT-X-ENDLIST\n"
        files[v] = Data(media.utf8)
        let originFiles = files
        FakeOrigin.state.withLock { $0 = (originFiles, false) }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("axr-stream-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FakeOrigin.self]
        let proxy = HLSCachingProxy(cache: StreamSegmentCache(root: root), configuration: config,
                                    estimateKey: "test.\(UUID().uuidString)")
        let video = "vid\(UUID().uuidString.prefix(6))"

        let entry = try #require(await proxy.startSession(
            videoID: video, masterURL: URL(string: "https://m.example/master.m3u8")!,
            headers: ["User-Agent": "t"], preferredMaxHeight: 360
        ))
        let (masterData, masterStatus) = try await get(entry)
        let masterText = String(decoding: masterData, as: UTF8.self)
        #expect(masterStatus == 200)
        #expect(masterText.components(separatedBy: "#EXT-X-STREAM-INF").count == 2)
        let plPath = try #require(firstPath(in: masterText, containing: "/pl/"))
        let (plData, _) = try await get(local(entry, plPath))
        let plText = String(decoding: plData, as: UTF8.self)
        let segPath = try #require(firstPath(in: plText, containing: "/seg/"))
        let (seg0, segStatus) = try await get(local(entry, segPath))
        #expect(segStatus == 200 && seg0 == files["https://cdn.example/itag/134/sq/0/seg.ts"])

        // Background workers download the rest of the video.
        let cache = StreamSegmentCache(root: root)
        for _ in 0..<100 where await cache.cachedIndices(video: video, rendition: "itag134").count < 4 {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(await cache.cachedIndices(video: video, rendition: "itag134") == [0, 1, 2, 3])
        for _ in 0..<40 where await proxy.progress()?.isComplete != true {
            try await Task.sleep(for: .milliseconds(25))
        }
        let progress = await proxy.progress()
        #expect(progress?.isComplete == true)
        #expect(progress?.ranges == [0...20])

        // Offline reopen: everything comes from disk.
        FakeOrigin.state.withLock { $0.offline = true }
        let again = try #require(await proxy.startSession(
            videoID: video, masterURL: URL(string: "https://m.example/master.m3u8")!,
            headers: [:], preferredMaxHeight: nil
        ))
        let (m2, s2) = try await get(again)
        #expect(s2 == 200)
        let pl2 = try #require(firstPath(in: String(decoding: m2, as: UTF8.self), containing: "/pl/"))
        let (p2, _) = try await get(local(again, pl2))
        let lastSeg = try #require(String(decoding: p2, as: UTF8.self).components(separatedBy: .newlines).last { $0.contains("/seg/") })
        let (seg3, s3) = try await get(local(again, lastSeg))
        #expect(s3 == 200 && seg3 == files["https://cdn.example/itag/134/sq/3/seg.ts"])
        await proxy.endSession()
    }

    @Test func progressIsHonestAndPushedLive() async throws {
        let v = "https://m.example/hls_playlist/itag/134/v.m3u8"
        let a = "https://m.example/hls_playlist/itag/140/a.m3u8"
        let master = """
        #EXTM3U
        #EXT-X-MEDIA:URI="\(a)",TYPE=AUDIO,GROUP-ID="140",NAME="Default",DEFAULT=YES
        #EXT-X-STREAM-INF:BANDWIDTH=900000,CODECS="avc1.4d401e",RESOLUTION=640x360,AUDIO="140"
        \(v)
        """
        var files: [String: Data] = ["https://m.example/m2.m3u8": Data(master.utf8)]
        for (pl, itag) in [(v, 134), (a, 140)] {
            var text = "#EXTM3U\n"
            for i in 0..<3 {
                let seg = "https://cdn.example/itag/\(itag)/sq/\(i)/seg.ts"
                text += "#EXTINF:5.0,\n\(seg)\n"
                files[seg] = Data(repeating: UInt8(i), count: 70_000)
            }
            files[pl] = Data((text + "#EXT-X-ENDLIST\n").utf8)
        }
        let originFiles = files
        FakeOrigin.state.withLock { $0 = (originFiles, false) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("axr-stream-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FakeOrigin.self]
        let proxy = HLSCachingProxy(cache: StreamSegmentCache(root: root), configuration: config,
                                    estimateKey: "test.\(UUID().uuidString)")
        let entry = try #require(await proxy.startSession(
            videoID: "honest\(UUID().uuidString.prefix(4))", masterURL: URL(string: "https://m.example/m2.m3u8")!,
            headers: [:], preferredMaxHeight: nil
        ))
        let updates = await proxy.progressUpdates()
        let masterText = String(decoding: try await get(entry).0, as: UTF8.self)
        let paths = masterText.components(separatedBy: .newlines).compactMap { line -> String? in
            if let r = line.range(of: "URI=\"") { return String(line[r.upperBound...].prefix { $0 != "\"" }) }
            return line.hasPrefix("/") ? line : nil
        }
        #expect(paths.count == 2)
        let videoPath = try #require(paths.first { !masterText.contains("URI=\"\($0)") })
        let audioPath = try #require(paths.first { masterText.contains("URI=\"\($0)") })

        // Video known, audio not yet: nothing is claimed as playable offline.
        _ = try await get(local(entry, videoPath))
        #expect(await proxy.progress() == nil)
        _ = try await get(local(entry, audioPath))

        // Updates arrive as segments land, ending complete.
        var last: StreamCacheProgress?
        for await value in updates {
            last = value
            if value?.isComplete == true { break }
        }
        #expect(last?.ranges == [0...15])

        await proxy.clearCache()
        #expect(await proxy.progress()?.ranges == [])
        #expect(await proxy.progress()?.isComplete == false)
        await proxy.endSession()
    }
}

@Suite("Up-next head prefetch", .serialized)
struct UpNextPrefetchTests {
    @Test func headIsCachedAndReusedBySession() async throws {
        let v360 = "https://m.example/hls_playlist/itag/134/v.m3u8"
        let v720 = "https://m.example/hls_playlist/itag/136/v.m3u8"
        let a = "https://m.example/hls_playlist/itag/140/a.m3u8"
        let master = """
        #EXTM3U
        #EXT-X-MEDIA:URI="\(a)",TYPE=AUDIO,GROUP-ID="140",NAME="Default",DEFAULT=YES
        #EXT-X-STREAM-INF:BANDWIDTH=900000,RESOLUTION=640x360,AUDIO="140"
        \(v360)
        #EXT-X-STREAM-INF:BANDWIDTH=2500000,RESOLUTION=1280x720,AUDIO="140"
        \(v720)
        """
        var files: [String: Data] = ["https://m.example/next.m3u8": Data(master.utf8)]
        for (pl, itag) in [(v360, 134), (v720, 136), (a, 140)] {
            var text = "#EXTM3U\n"
            for i in 0..<20 {   // 20 × 6 s = 2 min
                let seg = "https://cdn.example/n/\(itag)/\(i).ts"
                text += "#EXTINF:6.0,\n\(seg)\n"
                files[seg] = Data(repeating: UInt8(i), count: 1_000)
            }
            files[pl] = Data((text + "#EXT-X-ENDLIST\n").utf8)
        }
        let originFiles = files
        FakeOrigin.state.withLock { $0 = (originFiles, false) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("axr-next-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FakeOrigin.self]
        let cache = StreamSegmentCache(root: root.appendingPathComponent("c"), pinnedRoot: root.appendingPathComponent("p"))
        let proxy = HLSCachingProxy(cache: cache, configuration: config, estimateKey: "t.\(UUID().uuidString)")

        await proxy.prefetchHead(videoID: "next", masterURL: URL(string: "https://m.example/next.m3u8")!,
                                 headers: [:], preferredMaxHeight: 360, seconds: 60)
        #expect(await cache.cachedIndices(video: "next", rendition: "itag134") == Set(0..<10))
        #expect(await cache.cachedIndices(video: "next", rendition: "itag140") == Set(0..<10))
        #expect(await cache.cachedIndices(video: "next", rendition: "itag136").isEmpty)

        // Playing it later at a higher cap still uses the prefetched variant.
        let entry = try #require(await proxy.startSession(
            videoID: "next", masterURL: URL(string: "https://m.example/next.m3u8")!, headers: [:], preferredMaxHeight: 1080
        ))
        let (data, _) = try await URLSession.shared.data(from: entry)
        #expect(String(decoding: data, as: UTF8.self).contains("RESOLUTION=640x360"))
        await proxy.endSession()
    }
}

@Suite("Data saver: audio-only streaming", .serialized)
struct DataSaverTests {
    @Test func policyHonoursModeNetworkAndPerVideoChoice() {
        func decide(_ mode: AppSettings.DataSaverMode, mobile: Bool, video: Bool = false, legacy: Bool = false) -> Bool {
            DataSaverPolicy.streamsAudioOnly(mode: mode, audioOnlySetting: legacy, onMobileNetwork: mobile, videoRequested: video)
        }
        #expect(!decide(.off, mobile: true))
        #expect(decide(.cellular, mobile: true))
        #expect(!decide(.cellular, mobile: false))
        #expect(decide(.always, mobile: false))
        #expect(!decide(.always, mobile: true, video: true))
        #expect(decide(.off, mobile: false, legacy: true))
    }

    @Test func audioOnlySessionNeverTouchesVideo() async throws {
        let v = "https://m.example/hls_playlist/itag/134/v.m3u8"
        let a = "https://m.example/hls_playlist/itag/140/a.m3u8"
        let master = """
        #EXTM3U
        #EXT-X-MEDIA:URI="\(a)",TYPE=AUDIO,GROUP-ID="140",NAME="Default",DEFAULT=YES
        #EXT-X-STREAM-INF:BANDWIDTH=900000,RESOLUTION=640x360,AUDIO="140"
        \(v)
        """
        var files: [String: Data] = ["https://m.example/saver.m3u8": Data(master.utf8)]
        var text = "#EXTM3U\n"
        for i in 0..<3 {
            let seg = "https://cdn.example/s/140/\(i).aac"
            text += "#EXTINF:5.0,\n\(seg)\n"
            files[seg] = Data(repeating: UInt8(i), count: 70_000)
        }
        files[a] = Data((text + "#EXT-X-ENDLIST\n").utf8)   // the video playlist is absent on purpose
        let originFiles = files
        FakeOrigin.state.withLock { $0 = (originFiles, false) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("axr-saver-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FakeOrigin.self]
        let cache = StreamSegmentCache(root: root.appendingPathComponent("c"), pinnedRoot: root.appendingPathComponent("p"))
        let proxy = HLSCachingProxy(cache: cache, configuration: config, estimateKey: "t.\(UUID().uuidString)")
        let entry = try #require(await proxy.startSession(
            videoID: "saver", masterURL: URL(string: "https://m.example/saver.m3u8")!, headers: [:],
            preferredMaxHeight: nil, audioOnly: true
        ))
        let masterText = String(decoding: try await URLSession.shared.data(from: entry).0, as: UTF8.self)
        #expect(!masterText.contains("RESOLUTION"))
        let path = try #require(masterText.components(separatedBy: .newlines).first { $0.hasPrefix("/") })
        let (pl, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(entry.port!)\(path)")!)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(decoding: pl, as: UTF8.self).contains("/seg/"))
        let updates = await proxy.progressUpdates()
        for await value in updates where value?.isComplete == true { break }
        #expect(await proxy.progress()?.ranges == [0...15])
        #expect(await cache.cachedIndices(video: "saver", rendition: "itag140") == [0, 1, 2])
        #expect(await cache.cachedIndices(video: "saver", rendition: "itag134").isEmpty)
        await proxy.endSession()
    }
}
