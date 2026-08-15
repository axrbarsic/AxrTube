// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// The background file/HLS split and task restoration design are adapted from
// Brave iOS Playlist. AxrTube resolves media through its existing InnerTube
// client because it is a native catalog, not a browser DOM host.

import AVFoundation
import Foundation
import Observation
import iPocketTubeCore

private let downloadLog = CrashlyticsLogger(category: "PlaylistDownload")

@MainActor
@Observable
public final class VideoDownloadService {
    public enum DownloadState: Equatable {
        case idle
        case fetching
        case downloading(progress: Double)
        case saving
        case done
        case failed(String)

        public var isActive: Bool {
            switch self {
            case .fetching, .downloading, .saving: true
            default: false
            }
        }
    }

    public private(set) var state: DownloadState = .idle
    public private(set) var lastCompletedKind: OfflineMediaKind?
    public private(set) var lastSavedToPhotos = false
    public private(set) var lastWasAutomatic = false

    private let api: InnerTubeAPI
    private let backend: PlaylistDownloadBackend
    private var resolverTask: Task<Void, Never>?
    private var activeVideo: Video?
    private var attemptedFileFallbacks: Set<String> = []
    private var storageLimitBytes: Int64 = 4 * 1_024 * 1_024 * 1_024

    public init(api: InnerTubeAPI = InnerTubeAPI()) {
        self.api = api
        self.backend = PlaylistDownloadBackend.shared
        backend.onEvent = { [weak self] event in
            Task { @MainActor [weak self] in self?.handle(event) }
        }
        backend.restoreTasks()
    }

    public nonisolated static func handleBackgroundEvents(
        identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        PlaylistDownloadBackend.shared.handleBackgroundEvents(
            identifier: identifier,
            completionHandler: completionHandler
        )
    }

    public func download(
        video: Video,
        kind: OfflineMediaKind = .video,
        saveVideoToPhotos: Bool = false,
        storageLimitMB: Int = 4_096,
        isAutomatic: Bool = false,
        preferLowBandwidthAudio: Bool = false
    ) {
        guard !state.isActive else { return }
        guard kind == .video else {
            state = .failed("AxrTube теперь сохраняет полноценное видео. Аудио-загрузка удалена.")
            return
        }
        let store = DownloadStore.shared
        if store.containsCompleted(videoId: video.id, kind: .video) {
            lastCompletedKind = .video
            state = .done
            return
        }
        storageLimitBytes = Int64(max(256, storageLimitMB)) * 1_024 * 1_024
        guard store.canStore(additionalBytes: 0, limitBytes: storageLimitBytes) else {
            state = .failed("Достигнут лимит хранилища офлайн-видео.")
            return
        }
        guard store.begin(video: video, kind: .video) else { return }
        activeVideo = video
        lastWasAutomatic = isAutomatic
        lastSavedToPhotos = false
        state = .fetching
        store.update(videoId: video.id, kind: .video, status: .fetching, progress: 0)
        resolverTask = Task { [weak self] in await self?.resolveAndStart(video) }
    }

    public func retry(entry: DownloadedVideo, storageLimitMB: Int = 4_096) {
        download(video: entry.video, kind: .video, storageLimitMB: storageLimitMB)
    }

    public func cancel() {
        resolverTask?.cancel()
        if let video = activeVideo {
            backend.cancel(videoID: video.id)
            let progress = DownloadStore.shared.entry(videoId: video.id, kind: .video)?.progress ?? 0
            DownloadStore.shared.update(
                videoId: video.id,
                kind: .video,
                status: .paused,
                progress: progress,
                errorMessage: "Загрузка приостановлена.",
                resumePolicy: .manual
            )
        }
        state = .idle
    }

    public func reset() {
        resolverTask = nil
        if !state.isActive { state = .idle }
    }

    private func resolveAndStart(_ video: Video) async {
        do {
            let primary = try await api.fetchPlayerInfoForDownload(videoId: video.id)
            try Task.checkCancellation()
            if case let .hls(hlsURL) = PlaylistDownloadPolicy.source(
                hlsURL: primary.hlsURL,
                muxedFileURL: primary.bestMuxedDownloadURL
            ) {
                downloadLog.notice("[playlist] HLS selected for \(video.id)")
                backend.startHLS(video: video, url: hlsURL)
                return
            }
            if case let .file(fileURL) = PlaylistDownloadPolicy.source(
                hlsURL: primary.hlsURL,
                muxedFileURL: primary.bestMuxedDownloadURL
            ) {
                downloadLog.notice("[playlist] muxed MP4 selected for \(video.id)")
                backend.startFile(video: video, url: fileURL)
                return
            }
            let fallback = try await api.fetchPlayerInfoAndroid(videoId: video.id)
            try Task.checkCancellation()
            guard let fileURL = fallback.bestMuxedDownloadURL else {
                throw PlaylistDownloadError.noVideoResource
            }
            backend.startFile(video: video, url: fileURL)
        } catch is CancellationError {
            return
        } catch {
            fail(videoID: video.id, message: error.localizedDescription)
        }
    }

    private func handle(_ event: PlaylistDownloadBackend.Event) {
        switch event {
        case let .restored(videoID, progress):
            guard let entry = DownloadStore.shared.entry(videoId: videoID, kind: .video),
                  entry.status != .completed else { return }
            DownloadStore.shared.update(
                videoId: videoID,
                kind: .video,
                status: .downloading,
                progress: progress,
                resumePolicy: .automatic
            )
            if activeVideo?.id == videoID { state = .downloading(progress: progress) }

        case let .progress(videoID, progress):
            DownloadStore.shared.update(
                videoId: videoID,
                kind: .video,
                status: .downloading,
                progress: progress,
                resumePolicy: .automatic
            )
            if activeVideo?.id == videoID { state = .downloading(progress: progress) }

        case let .completed(videoID, location):
            guard let entry = DownloadStore.shared.entry(videoId: videoID, kind: .video) else { return }
            state = .saving
            do {
                let finalURL = try PlaylistDownloadBackend.preparePermanentLocation(
                    source: location,
                    videoID: videoID,
                    store: DownloadStore.shared
                )
                let bytes = PlaylistDownloadBackend.allocatedSize(at: finalURL)
                guard DownloadStore.shared.canStore(
                    additionalBytes: max(0, bytes - entry.fileSizeBytes),
                    limitBytes: storageLimitBytes
                ) else { throw PlaylistDownloadError.storageLimit }
                DownloadStore.shared.complete(
                    video: entry.video,
                    kind: .video,
                    fileURL: finalURL,
                    fileSizeBytes: bytes
                )
                lastCompletedKind = .video
                state = .done
            } catch {
                fail(videoID: videoID, message: error.localizedDescription)
            }

        case let .failed(videoID, source, message):
            if source == .hls, !attemptedFileFallbacks.contains(videoID),
               let video = DownloadStore.shared.entry(videoId: videoID, kind: .video)?.video {
                attemptedFileFallbacks.insert(videoID)
                state = .fetching
                resolverTask = Task { [weak self] in
                    guard let self else { return }
                    do {
                        let fallback = try await api.fetchPlayerInfoAndroid(videoId: videoID)
                        try Task.checkCancellation()
                        guard let fileURL = fallback.bestMuxedDownloadURL else {
                            throw PlaylistDownloadError.noVideoResource
                        }
                        backend.startFile(video: video, url: fileURL)
                    } catch is CancellationError {
                        return
                    } catch {
                        fail(videoID: videoID, message: "HLS недоступен. MP4 fallback: \(error.localizedDescription)")
                    }
                }
            } else {
                fail(videoID: videoID, message: message)
            }
        }
    }

    private func fail(videoID: String, message: String) {
        DownloadStore.shared.update(
            videoId: videoID,
            kind: .video,
            status: .failed,
            progress: DownloadStore.shared.entry(videoId: videoID, kind: .video)?.progress ?? 0,
            errorMessage: message,
            resumePolicy: .automatic
        )
        if activeVideo?.id == videoID { state = .failed(message) }
    }
}

private enum PlaylistDownloadError: LocalizedError {
    case noVideoResource
    case storageLimit
    case invalidTemporaryFile

    var errorDescription: String? {
        switch self {
        case .noVideoResource: "Для этого ролика не найден совместимый видеопоток."
        case .storageLimit: "Видеофайл превышает доступный лимит офлайн-хранилища."
        case .invalidTemporaryFile: "Система не сохранила загруженное видео."
        }
    }
}

private final class PlaylistDownloadBackend: NSObject, @unchecked Sendable,
    URLSessionDownloadDelegate, AVAssetDownloadDelegate {

    enum Event: Sendable {
        case restored(videoID: String, progress: Double)
        case progress(videoID: String, progress: Double)
        case completed(videoID: String, location: URL)
        case failed(videoID: String, source: PlaylistTaskIdentity.Kind, message: String)
    }

    static let shared = PlaylistDownloadBackend()
    var onEvent: (@Sendable (Event) -> Void)?

    private let lock = NSLock()
    private var hlsLocations: [Int: URL] = [:]
    private var backgroundCompletionHandlers: [String: () -> Void] = [:]

    func handleBackgroundEvents(identifier: String, completionHandler: @escaping () -> Void) {
        lock.withLock { backgroundCompletionHandlers[identifier] = completionHandler }
        _ = identifier == fileSession.configuration.identifier ? fileSession : hlsSession
    }

    private lazy var fileSession: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: "com.axrtube.playlist.files")
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    private lazy var hlsSession: AVAssetDownloadURLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: "com.axrtube.playlist.hls")
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        return AVAssetDownloadURLSession(
            configuration: config,
            assetDownloadDelegate: self,
            delegateQueue: nil
        )
    }()

    func startFile(video: Video, url: URL) {
        var request = URLRequest(url: url)
        request.setValue(InnerTubeClients.iOS.userAgent, forHTTPHeaderField: "User-Agent")
        let task = fileSession.downloadTask(with: request)
        task.taskDescription = PlaylistTaskIdentity(kind: .file, videoID: video.id).taskDescription
        task.resume()
    }

    func startHLS(video: Video, url: URL) {
        let asset = AVURLAsset(
            url: url,
            options: ["AVURLAssetHTTPHeaderFieldsKey": ["User-Agent": InnerTubeClients.iOS.userAgent]]
        )
        let configuration = AVAssetDownloadConfiguration(asset: asset, title: video.title)
        let task = hlsSession.makeAssetDownloadTask(downloadConfiguration: configuration)
        task.taskDescription = PlaylistTaskIdentity(kind: .hls, videoID: video.id).taskDescription
        task.resume()
    }

    func cancel(videoID: String) {
        fileSession.getAllTasks { tasks in
            tasks.filter { PlaylistTaskIdentity(taskDescription: $0.taskDescription)?.videoID == videoID }.forEach { $0.cancel() }
        }
        hlsSession.getAllTasks { tasks in
            tasks.filter { PlaylistTaskIdentity(taskDescription: $0.taskDescription)?.videoID == videoID }.forEach { $0.cancel() }
        }
    }

    func restoreTasks() {
        let report: @Sendable ([URLSessionTask]) -> Void = { [weak self] tasks in
            guard let self else { return }
            for task in tasks where task.state == .running || task.state == .suspended {
                guard let videoID = PlaylistTaskIdentity(taskDescription: task.taskDescription)?.videoID else { continue }
                self.onEvent?(.restored(videoID: videoID, progress: task.progress.fractionCompleted))
                if task.state == .suspended { task.resume() }
            }
        }
        fileSession.getAllTasks(completionHandler: report)
        hlsSession.getAllTasks(completionHandler: report)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard let videoID = PlaylistTaskIdentity(taskDescription: downloadTask.taskDescription)?.videoID,
              totalBytesExpectedToWrite > 0 else { return }
        onEvent?(.progress(
            videoID: videoID,
            progress: min(0.99, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
        ))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let videoID = PlaylistTaskIdentity(taskDescription: downloadTask.taskDescription)?.videoID else { return }
        do {
            let staging = FileManager.default.temporaryDirectory
                .appendingPathComponent("axrtube-\(UUID().uuidString).mp4")
            try FileManager.default.moveItem(at: location, to: staging)
            onEvent?(.completed(videoID: videoID, location: staging))
        } catch {
            onEvent?(.failed(videoID: videoID, source: .file, message: error.localizedDescription))
        }
    }

    func urlSession(
        _ session: URLSession,
        assetDownloadTask: AVAssetDownloadTask,
        willDownloadTo location: URL
    ) {
        lock.withLock { hlsLocations[assetDownloadTask.taskIdentifier] = location }
    }

    func urlSession(
        _ session: URLSession,
        assetDownloadTask: AVAssetDownloadTask,
        didLoad timeRange: CMTimeRange,
        totalTimeRangesLoaded loadedTimeRanges: [NSValue],
        timeRangeExpectedToLoad: CMTimeRange
    ) {
        guard let videoID = PlaylistTaskIdentity(taskDescription: assetDownloadTask.taskDescription)?.videoID else { return }
        let expected = timeRangeExpectedToLoad.duration.seconds
        let loaded = loadedTimeRanges.reduce(0.0) { $0 + $1.timeRangeValue.duration.seconds }
        guard expected.isFinite, expected > 0 else { return }
        onEvent?(.progress(videoID: videoID, progress: min(0.99, loaded / expected)))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let videoID = PlaylistTaskIdentity(taskDescription: task.taskDescription)?.videoID else { return }
        if let error {
            if (error as NSError).code != NSURLErrorCancelled {
                let source = PlaylistTaskIdentity(taskDescription: task.taskDescription)?.kind ?? .file
                onEvent?(.failed(videoID: videoID, source: source, message: error.localizedDescription))
            }
            return
        }
        guard task is AVAssetDownloadTask else { return }
        let location = lock.withLock { hlsLocations.removeValue(forKey: task.taskIdentifier) }
        guard let location else {
            onEvent?(.failed(videoID: videoID, source: .hls, message: PlaylistDownloadError.invalidTemporaryFile.localizedDescription))
            return
        }
        onEvent?(.completed(videoID: videoID, location: location))
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        guard let identifier = session.configuration.identifier else { return }
        let completion = lock.withLock { backgroundCompletionHandlers.removeValue(forKey: identifier) }
        DispatchQueue.main.async { completion?() }
    }

    @MainActor
    static func preparePermanentLocation(source: URL, videoID: String, store: DownloadStore) throws -> URL {
        if source.pathExtension == "movpkg" {
            return source
        }
        let destination = store.destinationURL(for: videoID, kind: .video)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: source, to: destination)
        return destination
    }

    static func allocatedSize(at url: URL) -> Int64 {
        if let bytes = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize {
            return Int64(bytes)
        }
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey]
        ) else { return 0 }
        return enumerator.reduce(into: Int64(0)) { total, value in
            guard let fileURL = value as? URL,
                  let size = try? fileURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize else { return }
            total += Int64(size)
        }
    }

}
