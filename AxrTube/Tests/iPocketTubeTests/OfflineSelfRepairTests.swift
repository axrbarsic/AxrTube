import Foundation
import Testing
@testable import iPocketTubeCore

@Suite("Offline metadata self repair") @MainActor
struct OfflineSelfRepairTests {
    private let media = Data([0, 0, 0, 16, 102, 116, 121, 112, 105, 115, 111, 109, 0, 0, 0, 0])

    @Test func uniqueFinalFileSurvivesContainerMove() throws {
        let old = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let moved = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: old); try? FileManager.default.removeItem(at: moved) }
        let store = DownloadStore(baseDirectory: old)
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        let video = Video(id: "test_video", title: "Test", channelTitle: "Test")
        let file = store.destinationURL(for: video.id + "-" + UUID().uuidString, kind: .video)
        try media.write(to: file)
        store.complete(video: video, kind: .video, fileURL: file, fileSizeBytes: Int64(media.count))
        try FileManager.default.moveItem(at: old, to: moved)
        let restored = DownloadStore(baseDirectory: moved)
        let entry = try #require(restored.entry(videoId: video.id, kind: .video))
        #expect(entry.status == .completed)
        #expect(entry.fileURL.deletingLastPathComponent().standardizedFileURL == moved.standardizedFileURL)
        #expect(try Data(contentsOf: entry.fileURL) == media)
        #expect(restored.reconcileLocalFiles() == 0)
    }

    @Test func repairsMissingPathDuringRuntimeWithoutDownloading() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DownloadStore(baseDirectory: root)
        let video = Video(id: "repair", title: "Test", channelTitle: "Test")
        _ = store.begin(video: video, kind: .video)
        store.update(videoId: video.id, kind: .video, status: .failed, progress: 0,
                     errorMessage: "Offline file is missing. Tap Retry.")
        let file = store.destinationURL(for: video.id + "-" + UUID().uuidString)
        try media.write(to: file)
        #expect(store.reconcileLocalFiles() == 1)
        #expect(store.entry(videoId: video.id, kind: .video)?.status == .completed)
        #expect(store.entry(videoId: video.id, kind: .video)?.fileURL.resolvingSymlinksInPath() == file.resolvingSymlinksInPath())
        #expect(store.reconcileLocalFiles() == 0)
    }

    @Test func ambiguityAndActiveTransfersAreLeftUntouched() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DownloadStore(baseDirectory: root)
        let video = Video(id: "ambiguous", title: "Test", channelTitle: "Test")
        _ = store.begin(video: video, kind: .video)
        for _ in 0..<2 {
            try media.write(to: store.destinationURL(for: video.id + "-" + UUID().uuidString))
        }
        #expect(store.reconcileLocalFiles() == 0)
        store.update(videoId: video.id, kind: .video, status: .failed, progress: 0,
                     errorMessage: "Offline file is missing. Tap Retry.")
        #expect(store.reconcileLocalFiles() == 0)
        #expect(store.entry(videoId: video.id, kind: .video)?.status == .failed)
    }
}
