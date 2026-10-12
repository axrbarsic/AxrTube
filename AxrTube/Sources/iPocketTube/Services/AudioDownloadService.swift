import AVFoundation
import Foundation
import Observation
import iPocketTubeCore
#if canImport(UIKit)
import UIKit
#endif

/// Saves a video's audio track as an offline `.m4a`.
///
/// Direct audio URLs need a PO token for most videos, while the HLS audio
/// rendition does not. The service downloads that rendition's packed-AAC
/// segments, joins them and remuxes the result into an M4A container without
/// re-encoding. Video downloads keep their own queue in `VideoDownloadService`.
@MainActor
@Observable
public final class AudioDownloadService {
    public private(set) var activeVideoIDs: Set<String> = []
    /// Short user-facing outcome for a toast; cleared by the presenter.
    public var lastMessage: String?

    private let api: InnerTubeAPI
    private let store: DownloadStore
    private var tasks: [String: Task<Void, Never>] = [:]

    public init(api: InnerTubeAPI, store: DownloadStore = .shared) {
        self.api = api
        self.store = store
    }

    public func isDownloading(videoID: String) -> Bool { activeVideoIDs.contains(videoID) }

    public func download(video: Video) {
        guard !store.containsCompleted(videoId: video.id, kind: .audio),
              !activeVideoIDs.contains(video.id),
              store.begin(video: video, kind: .audio) else {
            if store.containsCompleted(videoId: video.id, kind: .audio) { lastMessage = "Аудио уже сохранено" }
            return
        }
        activeVideoIDs.insert(video.id)
        lastMessage = "Сохраняем аудио…"
        store.update(videoId: video.id, kind: .audio, status: .fetching, progress: 0, resumePolicy: .manual)
        let api = api, store = store
        let temp = store.partialDownloadsDirectory.appendingPathComponent("\(video.id)-audio.aac")
        let destination = store.destinationURL(for: video.id, kind: .audio, fileExtension: "m4a")
        #if canImport(UIKit)
        let backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "AxrTube.AudioDownload")
        #endif
        tasks[video.id] = Task { [weak self] in
            defer {
                #if canImport(UIKit)
                UIApplication.shared.endBackgroundTask(backgroundTask)
                #endif
            }
            do {
                try await Self.fetchAudio(videoId: video.id, api: api, to: temp) { progress in
                    Task { @MainActor in
                        store.update(videoId: video.id, kind: .audio, status: .downloading,
                                     progress: progress * 0.95, resumePolicy: .manual)
                    }
                }
                let finalURL = try await Self.remuxToM4A(source: temp, destination: destination)
                try? FileManager.default.removeItem(at: temp)
                let bytes = (try? finalURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
                store.complete(video: video, kind: .audio, fileURL: finalURL, fileSizeBytes: bytes)
                self?.finish(video.id, message: "Аудио сохранено и доступно без интернета")
            } catch is CancellationError {
                try? FileManager.default.removeItem(at: temp)
                store.remove(videoId: video.id, kind: .audio)
                self?.finish(video.id, message: nil)
            } catch {
                try? FileManager.default.removeItem(at: temp)
                store.update(videoId: video.id, kind: .audio, status: .failed, progress: 0,
                             errorMessage: error.localizedDescription, resumePolicy: .manual)
                self?.finish(video.id, message: "Не удалось сохранить аудио")
            }
        }
    }

    public func cancel(videoID: String) {
        tasks[videoID]?.cancel()
    }

    private func finish(_ id: String, message: String?) {
        tasks[id] = nil
        activeVideoIDs.remove(id)
        if let message { lastMessage = message }
    }

    // MARK: - Pipeline (static so it can be exercised without the app store)

    enum AudioDownloadError: LocalizedError {
        case noHLS, noAudioRendition, emptyAudio, exportFailed

        var errorDescription: String? {
            switch self {
            case .noHLS: "YouTube не выдал поток для этого ролика."
            case .noAudioRendition: "В потоке нет отдельной аудиодорожки."
            case .emptyAudio: "Аудиодорожка пуста."
            case .exportFailed: "Не удалось упаковать аудио в M4A."
            }
        }
    }

    nonisolated static func fetchAudio(
        videoId: String,
        api: InnerTubeAPI,
        to output: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let info = try await api.fetchStartupPlayerInfo(videoId: videoId)
        guard let master = info.hlsURL else { throw AudioDownloadError.noHLS }
        let masterText = try await text(at: master)
        guard let playlistURL = HLSAudioExtraction.bestAudioPlaylistURL(masterText: masterText, masterURL: master)
        else { throw AudioDownloadError.noAudioRendition }
        let segments = HLSAudioExtraction.segmentURLs(playlistText: try await text(at: playlistURL), playlistURL: playlistURL)
        guard !segments.isEmpty else { throw AudioDownloadError.emptyAudio }

        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: output.path, contents: nil)
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close() }

        // A small window of parallel requests keeps order while hiding latency.
        let window = 4
        var index = 0
        while index < segments.count {
            try Task.checkCancellation()
            let batch = Array(segments[index ..< min(index + window, segments.count)])
            let parts = try await withThrowingTaskGroup(of: (Int, Data).self) { group in
                for (offset, url) in batch.enumerated() {
                    group.addTask { (offset, try await segment(at: url)) }
                }
                var result = [Data](repeating: Data(), count: batch.count)
                for try await (offset, data) in group { result[offset] = data }
                return result
            }
            for part in parts { try handle.write(contentsOf: HLSAudioExtraction.stripID3(part)) }
            index += batch.count
            progress(Double(index) / Double(segments.count))
        }
    }

    nonisolated static func remuxToM4A(source: URL, destination: URL) async throws -> URL {
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let asset = AVURLAsset(url: source)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw AudioDownloadError.exportFailed
        }
        do {
            try await export.export(to: destination, as: .m4a)
            return destination
        } catch {
            // Keep the playable ADTS stream rather than losing the download.
            let fallback = destination.deletingPathExtension().appendingPathExtension("aac")
            try? FileManager.default.removeItem(at: fallback)
            try FileManager.default.copyItem(at: source, to: fallback)
            return fallback
        }
    }

    private nonisolated static func text(at url: URL) async throws -> String {
        String(decoding: try await segment(at: url), as: UTF8.self)
    }

    private nonisolated static func segment(at url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue(InnerTubeClients.Web.userAgent, forHTTPHeaderField: "User-Agent")
        var lastError: Error = URLError(.unknown)
        for attempt in 0..<3 {
            try Task.checkCancellation()
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    throw URLError(.badServerResponse)
                }
                return data
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                try await Task.sleep(for: .milliseconds(400 * (attempt + 1)))
            }
        }
        throw lastError
    }
}
