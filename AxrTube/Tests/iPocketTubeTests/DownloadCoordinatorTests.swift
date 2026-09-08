import Foundation
import Testing
@testable import iPocketTube
@testable import iPocketTubeCore

private final class ControlledDownloadTransport: PlaylistDownloadTransport, @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var handler: (@Sendable (PlaylistDownloadEvent, UInt64) -> Void)?
    private var generations: [String: UInt64] = [:]
    private var cancelled: [String] = []
    private var started: [String] = []
    private var pressure = false
    private var restoreCompletion: (@Sendable (Set<String>) -> Void)?
    var onEvent: (@Sendable (PlaylistDownloadEvent, UInt64) -> Void)? {
        get { lock.withLock { handler } }
        set { lock.withLock { handler = newValue } }
    }
    var starts: [String] { lock.withLock { started } }
    var cancellations: [String] { lock.withLock { cancelled } }
    var isPressured: Bool { lock.withLock { pressure } }
    func startFile(video: Video, url: URL, userAgent: String) {
        lock.withLock { generations[video.id, default: 0] += 1; started.append(video.id) }
    }
    func startHLS(video: Video, url: URL, userAgent: String) { startFile(video: video, url: url, userAgent: userAgent) }
    func cancel(videoID: String) {
        lock.withLock { generations[videoID, default: 0] += 1; cancelled.append(videoID) }
    }
    func isCurrent(_ videoID: String, generation: UInt64) -> Bool {
        lock.withLock { generations[videoID, default: 0] == generation }
    }
    func restoreTasks(completion: @escaping @Sendable (Set<String>) -> Void) {
        lock.withLock { restoreCompletion = completion }
    }
    func finishRestoration(_ ids: Set<String> = []) {
        let completion = lock.withLock { let value = restoreCompletion; restoreCompletion = nil; return value }
        completion?(ids)
    }
    func setPlaybackPressure(_ pressured: Bool) { lock.withLock { pressure = pressured } }
    func emit(_ event: PlaylistDownloadEvent, generation: UInt64? = nil) {
        lock.withLock { handler?(event, generation ?? generations[event.videoID, default: 0]) }
    }
}

private actor ControlledOfflineResolver {
    private var continuations: [String: [CheckedContinuation<ResolvedOfflineSource, any Error>]] = [:]
    private var requests: [String] = []
    func resolve(_ video: Video) async throws -> ResolvedOfflineSource {
        requests.append(video.id)
        return try await withCheckedThrowingContinuation { continuation in
            continuations[video.id, default: []].append(continuation)
        }
    }
    func count(_ id: String) -> Int { requests.filter { $0 == id }.count }
    func succeed(_ id: String) {
        guard var pending = continuations[id], !pending.isEmpty else { return }
        let next = pending.removeFirst()
        continuations[id] = pending
        next.resume(returning: ResolvedOfflineSource(media: .file(URL(string: "https://example.com/fixture.mp4")!), userAgent: "Test"))
    }
}

@Suite("Production download coordinator") @MainActor
struct DownloadCoordinatorTests {
    private func video(_ id: String) -> Video { Video(id: id, title: id, channelTitle: "Fixture") }
    private func eventually(_ condition: @MainActor () async -> Bool) async throws {
        for _ in 0..<200 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(await condition(), "Coordinator did not reach the expected state")
    }

    @Test func cancellingQueuedRowDoesNotCancelPlayingDownloadAndResetDoesNotOwnQueue() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DownloadStore(baseDirectory: directory)
        let transport = ControlledDownloadTransport()
        let resolver = ControlledOfflineResolver()
        let service = VideoDownloadService(store: store, backend: transport, resolver: { video, _ in try await resolver.resolve(video) })
        service.download(video: video("A"))
        service.download(video: video("B"))
        service.download(video: video("C"))
        #expect(store.entries.count == 3)
        #expect(transport.starts.isEmpty)
        transport.finishRestoration()
        try await eventually { await resolver.count("A") == 1 }
        service.pause(videoID: "B")
        service.reset()
        #expect(service.activeVideoID == "A")
        #expect(transport.cancellations == ["B"])
        #expect(store.entry(videoId: "B", kind: .video)?.status == .paused)
        await resolver.succeed("A")
        try await eventually { transport.starts == ["A"] }
        transport.emit(.progress(videoID: "A", progress: 0.42))
        try await eventually { store.entry(videoId: "A", kind: .video)?.progress == 0.42 }
        service.pause(videoID: "A")
        try await eventually { await resolver.count("C") == 1 }
        #expect(service.activeVideoID == "C")
        #expect(store.entries.count == 3)
        service.cancelAll()
        await resolver.succeed("C")
    }

    @Test func staleResolverAndTransferCannotAffectNewRequestForSameVideo() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DownloadStore(baseDirectory: directory)
        let transport = ControlledDownloadTransport()
        let resolver = ControlledOfflineResolver()
        let service = VideoDownloadService(store: store, backend: transport, resolver: { video, _ in try await resolver.resolve(video) })
        transport.finishRestoration()
        service.download(video: video("A"))
        try await eventually { await resolver.count("A") == 1 }
        service.pause(videoID: "A")
        service.download(video: video("A"))
        try await eventually { await resolver.count("A") == 2 }
        await resolver.succeed("A")
        await resolver.succeed("A")
        try await eventually { transport.starts == ["A"] }
        transport.emit(.failed(videoID: "A", source: .file, message: "old error"), generation: 0)
        transport.emit(.progress(videoID: "A", progress: 0.6))
        try await eventually { store.entry(videoId: "A", kind: .video)?.progress == 0.6 }
        #expect(store.entry(videoId: "A", kind: .video)?.errorMessage == nil)
        #expect(service.activeVideoID == "A")
        service.cancelAll()
    }

    @Test func storageFailurePreservesAcceptedRowAndDoesNotBlockNextRequest() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DownloadStore(baseDirectory: directory)
        let old = video("existing")
        let file = store.destinationURL(for: old.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data([0, 0, 0, 16, 102, 116, 121, 112, 105, 115, 111, 109, 0, 0, 0, 0]).write(to: file)
        store.complete(video: old, kind: .video, fileURL: file, fileSizeBytes: 300 * 1_024 * 1_024)
        let transport = ControlledDownloadTransport()
        let resolver = ControlledOfflineResolver()
        let service = VideoDownloadService(store: store, backend: transport, resolver: { video, _ in try await resolver.resolve(video) })
        service.download(video: video("no-space"), storageLimitMB: 256)
        service.download(video: video("fits"), storageLimitMB: 1024)
        transport.finishRestoration()
        try await eventually { await resolver.count("fits") == 1 }
        #expect(store.entry(videoId: "no-space", kind: .video)?.status == .failed)
        #expect(store.entry(videoId: "no-space", kind: .video)?.resumePolicy == .manual)
        #expect(store.entries.count == 3)
        service.cancelAll()
        await resolver.succeed("fits")
    }

    @Test func restorationCannotResurrectDeletedOrManuallyPausedRows() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DownloadStore(baseDirectory: directory)
        let transport = ControlledDownloadTransport()
        let service = VideoDownloadService(store: store, backend: transport, resolver: { _, _ in throw CancellationError() })
        service.download(video: video("deleted"))
        service.download(video: video("paused"))
        service.cancel(videoIDs: ["deleted"])
        store.remove(videoId: "deleted", kind: .video)
        service.pause(videoID: "paused")
        transport.finishRestoration(["deleted", "paused"])
        try await eventually { transport.cancellations.count == 4 }
        #expect(service.activeVideoID == nil)
        #expect(transport.starts.isEmpty)
        #expect(store.entries.count == 1)
        #expect(store.entries.first?.status == .paused)
    }

    @Test func failedTransferWaitsWithoutBlockingAnotherVideo() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DownloadStore(baseDirectory: directory)
        let transport = ControlledDownloadTransport()
        let resolver = ControlledOfflineResolver()
        let service = VideoDownloadService(store: store, backend: transport, resolver: { video, _ in try await resolver.resolve(video) })
        transport.finishRestoration()
        service.download(video: video("A"))
        service.download(video: video("B"))
        try await eventually { await resolver.count("A") == 1 }
        await resolver.succeed("A")
        try await eventually { transport.starts == ["A"] }
        transport.emit(.progress(videoID: "A", progress: 0.3))
        transport.emit(.failed(videoID: "A", source: .file, message: "connection lost", errorCode: NSURLErrorNetworkConnectionLost))
        try await eventually { await resolver.count("B") == 1 }
        #expect(store.entry(videoId: "A", kind: .video)?.status == .reconnecting)
        #expect(store.entry(videoId: "A", kind: .video)?.progress == 0.3)
        service.pause(videoID: "A")
        #expect(service.activeVideoID == "B")
        await resolver.succeed("B")
        try await eventually { transport.starts == ["A", "B"] }
        let staged = directory.appendingPathComponent("fixture.mp4")
        try Data([0, 0, 0, 16, 102, 116, 121, 112, 105, 115, 111, 109, 0, 0, 0, 0]).write(to: staged)
        transport.emit(.completed(videoID: "B", location: staged))
        try await eventually { store.entry(videoId: "B", kind: .video)?.status == .completed }
        service.reset()
        #expect(store.entry(videoId: "A", kind: .video)?.status == .paused)
        #expect(store.entries.count == 2)
        #expect(service.activeVideoID == nil)
    }

    @Test func restoredTransferUsesConfiguredCapacityInsteadOfFourGBDefault() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DownloadStore(baseDirectory: directory)
        _ = store.begin(video: video("restored"), kind: .video)
        let existingURL = store.destinationURL(for: "existing")
        try Data([0, 0, 0, 16, 102, 116, 121, 112, 105, 115, 111, 109, 0, 0, 0, 0]).write(to: existingURL)
        store.complete(video: video("existing"), kind: .video, fileURL: existingURL, fileSizeBytes: 5 * 1_024 * 1_024 * 1_024)
        let transport = ControlledDownloadTransport()
        let service = VideoDownloadService(store: store, backend: transport,
            resolver: { _, _ in throw CancellationError() }, restoredStorageLimitMB: { 16 * 1_024 })
        transport.finishRestoration(["restored"])
        try await eventually { service.activeVideoID == "restored" }
        let staged = directory.appendingPathComponent("fixture.mp4")
        try Data(contentsOf: existingURL).write(to: staged)
        transport.emit(.completed(videoID: "restored", location: staged))
        try await eventually { store.entry(videoId: "restored", kind: .video)?.status == .completed }
        #expect(service.activeVideoID == nil)
    }

    @Test func restoredTransferCompletesWithoutResolvingOrDroppingQueuedRows() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let oldStore = DownloadStore(baseDirectory: directory)
        _ = oldStore.begin(video: video("restored"), kind: .video)
        let store = DownloadStore(baseDirectory: directory)
        let transport = ControlledDownloadTransport()
        let resolver = ControlledOfflineResolver()
        let service = VideoDownloadService(store: store, backend: transport, resolver: { video, _ in try await resolver.resolve(video) })
        service.download(video: video("new"))
        transport.emit(.restored(videoID: "restored", progress: 0.8))
        transport.finishRestoration(["restored"])
        try await eventually { service.activeVideoID == "restored" }
        #expect(await resolver.count("restored") == 0)
        let staged = directory.appendingPathComponent("fixture.mp4")
        try Data([0, 0, 0, 16, 102, 116, 121, 112, 105, 115, 111, 109, 0, 0, 0, 0]).write(to: staged)
        transport.emit(.completed(videoID: "restored", location: staged))
        try await eventually { await resolver.count("new") == 1 }
        #expect(store.entry(videoId: "restored", kind: .video)?.status == .completed)
        #expect(store.entries.count == 2)
        service.cancelAll()
        await resolver.succeed("new")
    }

    @Test func stalledPlaybackOnlyGetsBoundedBandwidthGrace() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DownloadStore(baseDirectory: directory)
        let transport = ControlledDownloadTransport()
        let service = VideoDownloadService(store: store, backend: transport,
            resolver: { _, _ in throw CancellationError() }, playbackGracePeriod: .milliseconds(10))
        transport.finishRestoration()
        service.setPlaybackDemand(preparing: true, waiting: true)
        #expect(transport.isPressured)
        try await eventually { !transport.isPressured }
        service.setPlaybackDemand(preparing: true, waiting: true)
        #expect(!transport.isPressured)
        service.setPlaybackDemand(preparing: false, waiting: false)
        service.setPlaybackDemand(preparing: false, waiting: true)
        #expect(transport.isPressured)
        service.setPlaybackDemand(preparing: false, waiting: false)
    }
}
