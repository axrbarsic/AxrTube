import Foundation
import Testing
@testable import iPocketTubeCore

@Suite("Saved videos built from the stream cache", .serialized)
struct PinnedStreamTests {
    private func tempRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("axr-pin-\(UUID().uuidString)")
    }

    @Test func pinKeepsCachedSegmentsAndSurvivesEvictionAndClearing() async {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = StreamSegmentCache(root: root.appendingPathComponent("c"), pinnedRoot: root.appendingPathComponent("p"), limitBytes: 1)
        await cache.storeSegment(Data(count: 10), video: "v1", rendition: "r", index: 0)
        #expect(await cache.pin("v1"))
        #expect(await cache.isPinned("v1"))
        #expect(await cache.segment(video: "v1", rendition: "r", index: 0)?.count == 10)
        // New segments of a saved video go to permanent storage.
        await cache.storeSegment(Data(count: 5), video: "v1", rendition: "r", index: 1)
        await cache.evictIfNeeded()
        await cache.removeAll()
        #expect(await cache.cachedIndices(video: "v1", rendition: "r") == [0, 1])
        #expect(await cache.totalBytes() == 0)
        await cache.unpin("v1")
        #expect(await cache.segment(video: "v1", rendition: "r", index: 0) == nil)
    }

    @MainActor
    @Test func libraryPinsUpdatesAndRemoves() async {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = StreamSegmentCache(root: root.appendingPathComponent("c"), pinnedRoot: root.appendingPathComponent("p"))
        let file = root.appendingPathComponent("lib.json")
        let library = PinnedStreamLibrary(fileURL: file, cache: cache)
        await library.pin(Video(id: "v2", title: "T", channelTitle: "C"), progress: 0.4, isComplete: false)
        #expect(library.pending == ["v2"])
        await library.update("v2", progress: 1, isComplete: true)
        #expect(library.pending.isEmpty)
        #expect(PinnedStreamLibrary(fileURL: file, cache: cache).entry("v2")?.isComplete == true)
        await library.remove("v2")
        #expect(library.entries.isEmpty)
        #expect(!(await cache.isPinned("v2")))
    }

    @Test func completerFinishesMissingSegmentsAndRefreshesExpiredURLs() async throws {
        // Old playlist points at expired URLs; the resolver yields a new master.
        var files: [String: Data] = [:]
        let fresh = "https://m.example/hls_playlist/itag/134/new.m3u8"
        files["https://m.example/new-master.m3u8"] = Data("""
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=900000,RESOLUTION=640x360
        \(fresh)
        """.utf8)
        var media = "#EXTM3U\n"
        for i in 0..<3 {
            let seg = "https://cdn.example/new/\(i).ts"
            media += "#EXTINF:5.0,\n\(seg)\n"
            files[seg] = Data(repeating: UInt8(i), count: 1_000)
        }
        files[fresh] = Data((media + "#EXT-X-ENDLIST\n").utf8)
        let originFiles = files
        FakeOrigin.state.withLock { $0 = (originFiles, false) }

        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = StreamSegmentCache(root: root.appendingPathComponent("c"), pinnedRoot: root.appendingPathComponent("p"))
        let video = "v3"
        let old = "https://m.example/hls_playlist/itag/134/old.m3u8"
        let oldText = "#EXTM3U\n#EXTINF:5.0,\nhttps://cdn.example/old/0.ts\n#EXTINF:5.0,\nhttps://cdn.example/old/1.ts\n#EXTINF:5.0,\nhttps://cdn.example/old/2.ts\n#EXT-X-ENDLIST\n"
        await cache.pin(video)
        await cache.storeSegment(Data(repeating: 0, count: 1_000), video: video, rendition: "itag134", index: 0)
        await cache.storeNamed(try JSONEncoder().encode(StreamSource(master: URL(string: "https://m.example/old-master.m3u8")!, headers: [:])),
                               video: video, name: StreamSource.fileName)
        await cache.storeNamed(Data("itag134".utf8), video: video, name: "rendition-video")
        await cache.storeNamed(Data(oldText.utf8), video: video, name: "pl-itag134")
        await cache.storeNamed(Data(old.utf8), video: video, name: "plurl-itag134")

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FakeOrigin.self]
        let proxy = HLSCachingProxy(cache: cache, configuration: config, estimateKey: "t.\(UUID().uuidString)")
        let completer = PinnedStreamCompleter(cache: cache, proxy: proxy, configuration: config)
        await completer.setResolver { _ in StreamSource(master: URL(string: "https://m.example/new-master.m3u8")!, headers: [:]) }

        let done = AsyncStream<Void>.makeStream()
        let finished = Locked(false)
        await completer.start(
            pending: { finished.value ? [] : [video] },
            report: { _, _, complete in
                if complete { finished.value = true; done.continuation.yield() }
            }
        )
        for await _ in done.stream { break }
        #expect(await cache.cachedIndices(video: video, rendition: "itag134") == [0, 1, 2])
        #expect(await cache.segment(video: video, rendition: "itag134", index: 2) == files["https://cdn.example/new/2.ts"])
    }
}

/// Tiny thread-safe box for test callbacks.
final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

@Suite("Unified downloads list")
struct DownloadLibraryListTests {
    @Test func mergesSourcesActiveFirstThenNewest() {
        let old = Date(timeIntervalSince1970: 100), new = Date(timeIntervalSince1970: 200)
        let saved = [
            PinnedStream(videoId: "s1", title: "S1", channelTitle: "c", thumbnailURL: nil, duration: 60,
                         pinnedAt: old, progress: 1, isComplete: true, bytes: 1_000_000),
            PinnedStream(videoId: "s2", title: "S2", channelTitle: "c", thumbnailURL: nil, duration: 60,
                         pinnedAt: old, progress: 0.4, isComplete: false, bytes: 0),
        ]
        let file = DownloadedVideo(videoId: "f1", title: "F1", channelTitle: "c", thumbnailURL: nil, duration: 60,
                                   fileURL: URL(fileURLWithPath: "/tmp/f1.m4a"), downloadedAt: new, kind: .audio,
                                   fileSizeBytes: 2_000_000)
        let items = DownloadLibraryList.items(saved: saved, files: [file])
        #expect(items.map(\.videoID) == ["s2", "f1", "s1"])
        #expect(DownloadLibraryList.status(items[0]) == "Скачивается · 40%")
        #expect(DownloadLibraryList.status(items[1]).hasPrefix("Аудио · "))
        #expect(DownloadLibraryList.status(items[2]).hasPrefix("Видео · "))
    }
}

@Suite("«Сохранённое»: watch later + phone")
struct SavedLibraryTests {
    private func pinned(_ id: String, complete: Bool = true, audio: Bool = false, watched: Bool = false) -> PinnedStream {
        var p = PinnedStream(videoId: id, title: id, channelTitle: "c", thumbnailURL: nil, duration: 60,
                             pinnedAt: Date(timeIntervalSince1970: 100), progress: complete ? 1 : 0.5,
                             isComplete: complete, bytes: 1_000)
        p.audioOnly = audio
        p.watchedAt = watched ? Date() : nil
        return p
    }

    @Test func watchLaterRowsAppearOnlyWhenNotOnThePhone() {
        let items = DownloadLibraryList.items(
            saved: [pinned("a")], files: [],
            watchLater: [Video(id: "a", title: "a", channelTitle: "c"), Video(id: "w", title: "w", channelTitle: "c")]
        )
        #expect(items.map(\.videoID) == ["a", "w"])
        #expect(items[1].source == .watchLater && items[1].state == .notDownloaded && items[1].isPlayable)
    }

    @Test func filtersSelectTheRightRows() {
        let items = DownloadLibraryList.items(saved: [pinned("v"), pinned("s", audio: true), pinned("d", watched: true)], files: [])
        #expect(items.filter(DownloadLibraryList.Filter.audio.includes).map(\.videoID) == ["s"])
        #expect(!items.filter(DownloadLibraryList.Filter.unwatched.includes).map(\.videoID).contains("d"))
        #expect(DownloadLibraryList.status(items.first { $0.videoID == "d" }!).hasSuffix("просмотрено"))
    }

    @MainActor
    @Test func videoSavesWaitForWiFiWhenAsked() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("axr-lib-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = StreamSegmentCache(root: root.appendingPathComponent("c"), pinnedRoot: root.appendingPathComponent("p"))
        let library = PinnedStreamLibrary(fileURL: root.appendingPathComponent("l.json"), cache: cache)
        await library.pin(Video(id: "video", title: "v", channelTitle: "c"), progress: 0, isComplete: false)
        await library.pin(Video(id: "sound", title: "s", channelTitle: "c"), progress: 0, isComplete: false, audioOnly: true)
        #expect(Set(library.pending(onMobileNetwork: true, videoOverWiFiOnly: true)) == ["sound"])
        #expect(Set(library.pending(onMobileNetwork: true, videoOverWiFiOnly: false)) == ["sound", "video"])
        #expect(Set(library.pending(onMobileNetwork: false, videoOverWiFiOnly: true)) == ["sound", "video"])
        library.markWatched("video")
        #expect(library.entry("video")?.watchedAt != nil)
    }

    @Test func neverPlayedVideoIsSavedThroughTheResolver() async throws {
        let v = "https://m.example/hls_playlist/itag/134/v.m3u8"
        let a = "https://m.example/hls_playlist/itag/140/a.m3u8"
        var files: [String: Data] = ["https://m.example/fresh.m3u8": Data("""
        #EXTM3U
        #EXT-X-MEDIA:URI="\(a)",TYPE=AUDIO,GROUP-ID="140",NAME="Default",DEFAULT=YES
        #EXT-X-STREAM-INF:BANDWIDTH=900000,RESOLUTION=640x360,AUDIO="140"
        \(v)
        """.utf8)]
        for (pl, itag) in [(v, 134), (a, 140)] {
            var text = "#EXTM3U\n"
            for i in 0..<2 {
                let seg = "https://cdn.example/b/\(itag)/\(i).ts"
                text += "#EXTINF:5.0,\n\(seg)\n"
                files[seg] = Data(repeating: UInt8(i), count: 500)
            }
            files[pl] = Data((text + "#EXT-X-ENDLIST\n").utf8)
        }
        let originFiles = files
        FakeOrigin.state.withLock { $0 = (originFiles, false) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("axr-boot-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FakeOrigin.self]
        let cache = StreamSegmentCache(root: root.appendingPathComponent("c"), pinnedRoot: root.appendingPathComponent("p"))
        let proxy = HLSCachingProxy(cache: cache, configuration: config, estimateKey: "t.\(UUID().uuidString)")
        let completer = PinnedStreamCompleter(cache: cache, proxy: proxy, configuration: config)
        await completer.setResolver { _ in StreamSource(master: URL(string: "https://m.example/fresh.m3u8")!, headers: [:]) }
        await cache.pin("fresh")
        await cache.storeNamed(Data("1".utf8), video: "fresh", name: PinnedStreamLibrary.audioOnlyMarker)

        let done = AsyncStream<Void>.makeStream()
        let finished = Locked(false)
        await completer.start(
            pending: { finished.value ? [] : ["fresh"] },
            report: { _, _, complete in if complete { finished.value = true; done.continuation.yield() } }
        )
        for await _ in done.stream { break }
        // Sound-only save: the audio track only, never the video.
        #expect(await cache.cachedIndices(video: "fresh", rendition: "itag140") == [0, 1])
        #expect(await cache.cachedIndices(video: "fresh", rendition: "itag134").isEmpty)
        #expect(await cache.isPinned("fresh"))
    }
}
