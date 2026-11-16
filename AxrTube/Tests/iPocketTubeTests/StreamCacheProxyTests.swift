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
}
