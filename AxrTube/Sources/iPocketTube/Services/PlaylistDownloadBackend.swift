// Copyright 2020 The Brave Authors. All rights reserved.
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// The background file/HLS split and task restoration design are adapted from
// Brave iOS Playlist. AxrTube resolves media through its existing InnerTube
// client because it is a native catalog, not a browser DOM host.

import AVFoundation
import Foundation
import iPocketTubeCore

private let downloadLog = CrashlyticsLogger(category: "PlaylistTransport")

enum PlaylistDownloadError: LocalizedError {
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

private final class RestoredTaskAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var videoIDs: Set<String> = []

    func insert(_ videoID: String) {
        _ = lock.withLock { videoIDs.insert(videoID) }
    }

    func snapshot() -> Set<String> {
        lock.withLock { videoIDs }
    }
}

final class PlaylistDownloadBackend: NSObject, @unchecked Sendable,
    URLSessionDownloadDelegate, AVAssetDownloadDelegate, PlaylistDownloadTransport {

    typealias Event = PlaylistDownloadEvent

    static let shared = PlaylistDownloadBackend()
    var onEvent: (@Sendable (Event, UInt64) -> Void)?

    private let lock = NSRecursiveLock()
    private var tasksByVideo: [String: URLSessionTask] = [:]
    private var cancelledVideos: Set<String> = []
    private var generations: [String: UInt64] = [:]
    private var playbackPressure = false
    private var hlsLocations: [Int: URL] = [:]
    private var backgroundCompletionHandlers: [String: () -> Void] = [:]
    private let rangeDefaults = UserDefaults.standard

    private func rangeJournal(videoID: String, url: URL) throws -> OfflineRangeJournal? {
        guard !rangeDefaults.bool(forKey: "offline.rangeUnsupported.\(videoID)"),
              let itag = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .first(where: { $0.name == "itag" })?.value,
              !itag.isEmpty else { return nil }
        let name = videoID.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? UUID().uuidString
        let format = itag.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? UUID().uuidString
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SmartTubeDownloads/.range-pieces", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
            .appendingPathComponent(format, isDirectory: true)
        return try OfflineRangeJournal(directory: directory, representation: "\(videoID):\(itag)")
    }

    func handleBackgroundEvents(identifier: String, completionHandler: @escaping () -> Void) {
        lock.withLock { backgroundCompletionHandlers[identifier] = completionHandler }
        _ = identifier == fileSession.configuration.identifier ? fileSession : hlsSession
    }

    private lazy var fileSession: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: "com.axrtube.playlist.files")
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        config.waitsForConnectivity = true
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 7 * 24 * 60 * 60
        config.httpMaximumConnectionsPerHost = 2
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    private lazy var hlsSession: AVAssetDownloadURLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: "com.axrtube.playlist.hls")
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        config.waitsForConnectivity = true
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 7 * 24 * 60 * 60
        return AVAssetDownloadURLSession(
            configuration: config,
            assetDownloadDelegate: self,
            delegateQueue: nil
        )
    }()

    func startFile(video: Video, url: URL, userAgent: String) {
        lock.lock(); defer { lock.unlock() }
        cancelledVideos.remove(video.id)
        generations[video.id, default: 0] &+= 1
        // Kept aligned with Brave Playlist's file downloader. The range header
        // avoids probe-only responses, while the playback session identifier
        // keeps a CDN request internally coherent across redirects.
        var request = PlaylistDownloadPolicy.fileRequest(
            url: url,
            userAgent: userAgent,
            playbackSessionID: UUID().uuidString
        )
        if let journal = try? rangeJournal(videoID: video.id, url: url) {
            if journal.isComplete {
                emit(.completed(videoID: video.id, location: journal.dataURL))
                return
            }
            request.setValue(journal.rangeHeader, forHTTPHeaderField: "Range")
            if let validator = journal.state.validator {
                request.setValue(validator, forHTTPHeaderField: "If-Range")
            }
        }
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let task: URLSessionDownloadTask
        if request.value(forHTTPHeaderField: "Range") == "bytes=0-",
           rangeDefaults.string(forKey: "offline.resumeURL.\(video.id)") == url.absoluteString,
           let resumeData = rangeDefaults.data(forKey: "offline.resume.\(video.id)") {
            task = fileSession.downloadTask(withResumeData: resumeData)
        } else {
            task = fileSession.downloadTask(with: request)
        }
        task.taskDescription = PlaylistTaskIdentity(kind: .file, videoID: video.id).taskDescription
        tasksByVideo[video.id] = task
        task.priority = URLSessionTask.lowPriority
        if !playbackPressure { task.resume() }
    }

    func startHLS(video: Video, url: URL, userAgent: String) {
        lock.lock(); defer { lock.unlock() }
        cancelledVideos.remove(video.id)
        generations[video.id, default: 0] &+= 1
        let asset = AVURLAsset(
            url: url,
            options: ["AVURLAssetHTTPHeaderFieldsKey": ["User-Agent": userAgent]]
        )
        let configuration = AVAssetDownloadConfiguration(asset: asset, title: video.title)
        let task = hlsSession.makeAssetDownloadTask(downloadConfiguration: configuration)
        task.taskDescription = PlaylistTaskIdentity(kind: .hls, videoID: video.id).taskDescription
        tasksByVideo[video.id] = task
        task.priority = URLSessionTask.lowPriority
        if !playbackPressure { task.resume() }
    }

    func setPlaybackPressure(_ pressured: Bool) {
        lock.withLock {
            guard playbackPressure != pressured else { return }
            playbackPressure = pressured
            for task in tasksByVideo.values {
                if pressured, task.state == .running { task.suspend() }
                if !pressured, task.state == .suspended { task.resume() }
            }
        }
    }

    func cancel(videoID: String) {
        lock.withLock {
            cancelledVideos.insert(videoID)
            generations[videoID, default: 0] &+= 1
            let task = tasksByVideo.removeValue(forKey: videoID)
            task?.cancel()
        }
    }

    func isCurrent(_ videoID: String, generation: UInt64) -> Bool {
        lock.withLock { !cancelledVideos.contains(videoID) && generations[videoID, default: 0] == generation }
    }

    private func emit(_ event: Event) {
        lock.withLock { onEvent?(event, generations[event.videoID, default: 0]) }
    }

    private func accepts(_ task: URLSessionTask) -> Bool {
        guard let id = PlaylistTaskIdentity(taskDescription: task.taskDescription)?.videoID,
              !cancelledVideos.contains(id) else { return false }
        return tasksByVideo[id] === task
    }

    func restoreTasks(completion: @escaping @Sendable (Set<String>) -> Void) {
        let group = DispatchGroup()
        let accumulator = RestoredTaskAccumulator()
        let report: @Sendable ([URLSessionTask]) -> Void = { [weak self] tasks in
            guard let self else { return }
            self.lock.lock(); defer { self.lock.unlock() }
            for task in tasks where task.state == .running || task.state == .suspended {
                guard let videoID = PlaylistTaskIdentity(taskDescription: task.taskDescription)?.videoID else { continue }
                if self.tasksByVideo[videoID] === task {
                    accumulator.insert(videoID)
                    continue
                }
                guard !self.cancelledVideos.contains(videoID), self.tasksByVideo[videoID] == nil else {
                    task.cancel()
                    continue
                }
                self.tasksByVideo[videoID] = task
                accumulator.insert(videoID)
                self.emit(.restored(videoID: videoID, progress: task.progress.fractionCompleted))
                if task.state == .suspended, !self.playbackPressure { task.resume() }
            }
        }
        group.enter()
        fileSession.getAllTasks { tasks in
            report(tasks)
            group.leave()
        }
        group.enter()
        hlsSession.getAllTasks { tasks in
            report(tasks)
            group.leave()
        }
        group.notify(queue: .global(qos: .utility)) {
            completion(accumulator.snapshot())
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        lock.lock(); defer { lock.unlock() }
        guard accepts(downloadTask) else { return }
        guard let videoID = PlaylistTaskIdentity(taskDescription: downloadTask.taskDescription)?.videoID,
              totalBytesExpectedToWrite > 0 else { return }
        if let url = downloadTask.originalRequest?.url,
           let journal = try? rangeJournal(videoID: videoID, url: url) {
            let progress = journal.state.total.map {
                Double(journal.state.committed + totalBytesWritten) / Double(max(1, $0))
            } ?? 0
            emit(.progress(videoID: videoID, progress: min(0.99, progress)))
            return
        }
        emit(.progress(
            videoID: videoID,
            progress: min(0.99, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
        ))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        lock.lock(); defer { lock.unlock() }
        guard accepts(downloadTask) else { return }
        guard let videoID = PlaylistTaskIdentity(taskDescription: downloadTask.taskDescription)?.videoID else { return }
        guard let response = downloadTask.response as? HTTPURLResponse,
              PlaylistDownloadPolicy.acceptsHTTPStatus(response.statusCode) else {
            emit(.failed(
                videoID: videoID,
                source: .file,
                message: PlaylistDownloadPolicy.failureMessage(
                    urlErrorCode: NSURLErrorBadServerResponse,
                    httpStatus: (downloadTask.response as? HTTPURLResponse)?.statusCode
                ),
                errorCode: NSURLErrorBadServerResponse,
                httpStatus: (downloadTask.response as? HTTPURLResponse)?.statusCode
            ))
            return
        }

        if response.statusCode == 206,
           let url = downloadTask.originalRequest?.url,
           let journal = try? rangeJournal(videoID: videoID, url: url),
           downloadTask.originalRequest?.value(forHTTPHeaderField: "Range")?.hasSuffix("-") == false {
            do {
                try journal.commit(piece: location,
                    contentRange: response.value(forHTTPHeaderField: "Content-Range") ?? "",
                    etag: response.value(forHTTPHeaderField: "ETag"))
                emit(.progress(videoID: videoID, progress: min(0.99, journal.progress)))
                if journal.isComplete {
                    emit(.completed(videoID: videoID, location: journal.dataURL))
                } else {
                    startFile(video: Video(id: videoID, title: "", channelTitle: ""), url: url,
                        userAgent: downloadTask.originalRequest?.value(forHTTPHeaderField: "User-Agent") ?? InnerTubeClients.Android.userAgent)
                }
            } catch OfflineRangeJournal.Failure.missingValidator {
                // Without a strong validator range recombination is unsafe.
                // Preserve the journal and use the system whole-file fallback.
                rangeDefaults.set(true, forKey: "offline.rangeUnsupported.\(videoID)")
                startFile(video: Video(id: videoID, title: "", channelTitle: ""), url: url,
                    userAgent: downloadTask.originalRequest?.value(forHTTPHeaderField: "User-Agent") ?? InnerTubeClients.Android.userAgent)
            } catch {
                emit(.failed(videoID: videoID, source: .file,
                    message: "Источник изменил содержимое или диапазон файла. Сохранённые куски оставлены для проверки."))
            }
            return
        }

        // A partial response to an open-ended request is not a complete file.
        if response.statusCode == 206 {
            guard let header = response.value(forHTTPHeaderField: "Content-Range"),
                  let range = OfflineRangeJournal.parse(header),
                  range.start == 0, range.end == range.total - 1 else {
                emit(.failed(videoID: videoID, source: .file,
                    message: "Источник вернул неполный файл. Загрузка не отмечена готовой."))
                return
            }
        }

        // Direct adaptation of Brave Playlist's three-stage media type
        // detection: URL suffix, HTTP Content-Type, then file signature.
        var detectedFileExtension = downloadTask.originalRequest?.url
            .map(PlaylistMimeTypeDetector.init(url:))?.fileExtension
        if detectedFileExtension == nil,
           let contentType = response.value(forHTTPHeaderField: "Content-Type") {
            detectedFileExtension = PlaylistMimeTypeDetector(mimeType: contentType).fileExtension
        }
        if detectedFileExtension == nil,
           let data = try? Data(contentsOf: location, options: .mappedIfSafe) {
            detectedFileExtension = PlaylistMimeTypeDetector(data: data).fileExtension
        }
        let fileExtension = detectedFileExtension ?? "mp4"
        do {
            let staging = FileManager.default.temporaryDirectory
                .appendingPathComponent("axrtube-\(UUID().uuidString).\(fileExtension)")
            try FileManager.default.moveItem(at: location, to: staging)
            emit(.completed(videoID: videoID, location: staging))
        } catch {
            emit(.failed(videoID: videoID, source: .file, message: error.localizedDescription))
        }
    }

    func urlSession(
        _ session: URLSession,
        assetDownloadTask: AVAssetDownloadTask,
        willDownloadTo location: URL
    ) {
        lock.withLock {
            guard accepts(assetDownloadTask) else { return }
            hlsLocations[assetDownloadTask.taskIdentifier] = location
        }
    }

    func urlSession(
        _ session: URLSession,
        assetDownloadTask: AVAssetDownloadTask,
        didLoad timeRange: CMTimeRange,
        totalTimeRangesLoaded loadedTimeRanges: [NSValue],
        timeRangeExpectedToLoad: CMTimeRange
    ) {
        lock.lock(); defer { lock.unlock() }
        guard accepts(assetDownloadTask) else { return }
        guard let videoID = PlaylistTaskIdentity(taskDescription: assetDownloadTask.taskDescription)?.videoID else { return }
        let expected = timeRangeExpectedToLoad.duration.seconds
        let loaded = loadedTimeRanges.reduce(0.0) { $0 + $1.timeRangeValue.duration.seconds }
        guard expected.isFinite, expected > 0 else { return }
        emit(.progress(videoID: videoID, progress: min(0.99, loaded / expected)))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock(); defer { lock.unlock() }
        guard accepts(task) else { return }
        guard let videoID = PlaylistTaskIdentity(taskDescription: task.taskDescription)?.videoID else { return }
        tasksByVideo.removeValue(forKey: videoID)
        let hlsLocation = lock.withLock { hlsLocations.removeValue(forKey: task.taskIdentifier) }
        if let error {
            if let hlsLocation { try? FileManager.default.removeItem(at: hlsLocation) }
            if (error as NSError).code != NSURLErrorCancelled {
                let source = PlaylistTaskIdentity(taskDescription: task.taskDescription)?.kind ?? .file
                let status = (task.response as? HTTPURLResponse)?.statusCode
                if task is URLSessionDownloadTask {
                    let key = "offline.resume.\(videoID)"
                    if status == 401 || status == 403 {
                        rangeDefaults.removeObject(forKey: key)
                    } else if let data = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
                        rangeDefaults.set(data, forKey: key)
                        rangeDefaults.set(task.originalRequest?.url?.absoluteString, forKey: "offline.resumeURL.\(videoID)")
                    }
                }
                downloadLog.error(
                    "[playlist] background \(source.rawValue) failed for \(videoID): "
                        + "http=\(status ?? 0) error=\((error as NSError).code)"
                )
                emit(.failed(
                    videoID: videoID,
                    source: source,
                    message: PlaylistDownloadPolicy.failureMessage(
                        urlErrorCode: (error as NSError).code,
                        httpStatus: status
                    ),
                    errorCode: (error as NSError).code,
                    httpStatus: status
                ))
            }
            return
        }
        guard task is AVAssetDownloadTask else {
            rangeDefaults.removeObject(forKey: "offline.resume.\(videoID)")
            return
        }
        guard let hlsLocation else {
            emit(.failed(videoID: videoID, source: .hls, message: PlaylistDownloadError.invalidTemporaryFile.localizedDescription))
            return
        }
        emit(.completed(videoID: videoID, location: hlsLocation))
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        guard let identifier = session.configuration.identifier else { return }
        let completion = lock.withLock { backgroundCompletionHandlers.removeValue(forKey: identifier) }
        DispatchQueue.main.async { completion?() }
    }

    func urlSession(_ session: URLSession, taskIsWaitingForConnectivity task: URLSessionTask) {
        lock.lock(); defer { lock.unlock() }
        guard accepts(task) else { return }
        guard let id = PlaylistTaskIdentity(taskDescription: task.taskDescription)?.videoID else { return }
        emit(.waiting(videoID: id))
    }

    @MainActor
    static func preparePermanentLocation(source: URL, videoID: String, store: DownloadStore) throws -> URL {
        // Brave moves both HLS packages and regular files out of the transient
        // system download location. Persisting the concrete extension also lets
        // AVPlayer identify containers without a custom resource loader.
        let fileExtension = source.pathExtension.isEmpty || source.pathExtension == "part" ? "mp4" : source.pathExtension
        let destination = store.destinationURL(
            for: videoID + "-" + UUID().uuidString,
            kind: .video,
            fileExtension: fileExtension
        )
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.moveItem(at: source, to: destination)
        return destination
    }

    static func allocatedSize(at url: URL) -> Int64 {
        if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true,
           let bytes = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize {
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
