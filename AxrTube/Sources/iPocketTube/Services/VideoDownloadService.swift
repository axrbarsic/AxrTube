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
import Observation
import Network
import iPocketTubeCore
#if canImport(UIKit)
import UIKit
#endif

/// One owner for durable requests. Presentation state never advances the queue.
@MainActor
@Observable
public final class VideoDownloadService {
    private struct Request {
        let token = UUID()
        let video: Video
        let storageLimitMB: Int
        let isAutomatic: Bool
        var retryAttempt = 0
        var usesRefreshedFile = false
        var limitBytes: Int64 { Int64(max(256, storageLimitMB)) * 1_024 * 1_024 }
    }

    public enum DownloadState: Equatable {
        case idle, fetching, downloading(progress: Double), saving, done, failed(String)
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
    public var activeVideoID: String? { currentRequest?.video.id }
    public var activeProgress: Double? {
        if case let .downloading(progress) = state { return progress }
        return nil
    }

    private let store: DownloadStore
    private let backend: any PlaylistDownloadTransport
    private let resolveSource: OfflineSourceResolver
    private let restoredStorageLimitMB: @MainActor () -> Int
    private var currentRequest: Request?
    private var pendingRequests: [Request] = []
    private var restoredVideoIDs: Set<String> = []
    private var isRestoring = false
    private var resolverTask: Task<Void, Never>?
    private var deferredRequests: [String: Request] = [:]
    private var retryTasks: [String: Task<Void, Never>] = [:]
    private var networkAvailable = true
    private var networkMonitor: NWPathMonitor?
    private var foregroundObserver: NSObjectProtocol?
    private var maintenanceTask: Task<Void, Never>?
    private var playbackObservation: NSKeyValueObservation?
    private weak var observedPlayer: AVPlayer?
    private var playbackPreparing = false
    private var pressureEpisodeActive = false
    private var pressureReleaseTask: Task<Void, Never>?
    private let playbackGracePeriod: Duration

    public convenience init(api: InnerTubeAPI = InnerTubeAPI(), settingsStore: SettingsStore? = nil) {
        let settings = settingsStore ?? SettingsStore()
        self.init(store: .shared, backend: PlaylistDownloadBackend.shared,
                  resolver: Self.nativeResolver(api: api), observeSystem: true,
                  restoredStorageLimitMB: { settings.settings.offlineStorageLimitMB })
    }

    /// Internal injection point exercises the production coordinator, not a copy
    /// of its policy. Native sessions and API requests remain production defaults.
    init(store: DownloadStore, backend: any PlaylistDownloadTransport,
         resolver: @escaping OfflineSourceResolver, observeSystem: Bool = false,
         playbackGracePeriod: Duration = .seconds(3),
         restoredStorageLimitMB: @escaping @MainActor () -> Int = { 4_096 }) {
        self.store = store
        self.backend = backend
        self.resolveSource = resolver
        self.restoredStorageLimitMB = restoredStorageLimitMB
        self.playbackGracePeriod = playbackGracePeriod
        backend.onEvent = { [weak self] event, generation in
            Task { @MainActor [weak self] in
                guard let self, backend.isCurrent(event.videoID, generation: generation) else { return }
                handle(event)
            }
        }
        restoreTransfers()
        if observeSystem { observeLifecycle() }
    }

    private static func nativeResolver(api: InnerTubeAPI) -> OfflineSourceResolver {
        { video, strategy in
            if case .preferred = strategy {
                do {
                    let info = try await api.fetchPlayerInfoForDownload(videoId: video.id)
                    try Task.checkCancellation()
                    if let media = PlaylistDownloadPolicy.source(
                        hlsURL: info.hlsURL, muxedFileURL: info.bestMuxedDownloadURL
                    ) { return ResolvedOfflineSource(media: media, userAgent: InnerTubeClients.iOS.userAgent) }
                } catch is CancellationError { throw CancellationError() }
                catch { /* A different native client may have a valid media source. */ }
            }
            let info = try await api.fetchPlayerInfoAndroid(videoId: video.id)
            try Task.checkCancellation()
            let media: PlaylistMediaSource?
            switch strategy {
            case .preferred:
                media = PlaylistDownloadPolicy.source(hlsURL: info.hlsURL, muxedFileURL: info.bestMuxedDownloadURL)
            case .refreshedFile:
                media = info.bestMuxedDownloadURL.map(PlaylistMediaSource.file)
            }
            guard let media else { throw PlaylistDownloadError.noVideoResource }
            return ResolvedOfflineSource(media: media, userAgent: InnerTubeClients.Android.userAgent)
        }
    }

    public nonisolated static func handleBackgroundEvents(
        identifier: String, completionHandler: @escaping () -> Void
    ) {
        PlaylistDownloadBackend.shared.handleBackgroundEvents(identifier: identifier, completionHandler: completionHandler)
    }

    public func download(video: Video, kind: OfflineMediaKind = .video,
                         saveVideoToPhotos: Bool = false, storageLimitMB: Int = 4_096,
                         isAutomatic: Bool = false, preferLowBandwidthAudio: Bool = false) {
        guard kind == .video else { return }
        guard !store.containsCompleted(videoId: video.id, kind: .video) else { return }
        guard currentRequest?.video.id != video.id,
              !pendingRequests.contains(where: { $0.video.id == video.id }),
              deferredRequests[video.id] == nil,
              !restoredVideoIDs.contains(video.id) else { return }
        // Persist BEFORE capacity checks or suspension. An accepted request must
        // remain visible even when the transport cannot start.
        _ = store.begin(video: video, kind: .video)
        guard store.entry(videoId: video.id, kind: .video)?.shouldAutomaticallyResume == true else { return }
        pendingRequests.append(Request(video: video, storageLimitMB: storageLimitMB, isAutomatic: isAutomatic))
        advanceQueue()
    }

    public func retry(entry: DownloadedVideo, storageLimitMB: Int = 4_096) {
        download(video: entry.video, storageLimitMB: storageLimitMB)
    }

    /// Pause the requested row, never whichever transfer happens to be active.
    public func pause(videoID: String) {
        guard store.entry(videoId: videoID, kind: .video)?.status != .completed else { return }
        let progress = store.entry(videoId: videoID, kind: .video)?.progress ?? 0
        store.update(videoId: videoID, kind: .video, status: .paused, progress: progress,
                     errorMessage: "Загрузка приостановлена.", resumePolicy: .manual)
        cancel(videoIDs: [videoID])
    }

    public func cancel(videoIDs: Set<String>) {
        pendingRequests.removeAll { videoIDs.contains($0.video.id) }
        restoredVideoIDs.subtract(videoIDs)
        for id in videoIDs {
            deferredRequests.removeValue(forKey: id)
            retryTasks.removeValue(forKey: id)?.cancel()
            backend.cancel(videoID: id)
        }
        if let request = currentRequest, videoIDs.contains(request.video.id) {
            releaseCurrentRequest()
            state = .idle
        }
        advanceQueue()
    }

    public func cancelAll() {
        let ids = Set(store.entries.filter { $0.kind == .video }.map(\.videoId))
        pendingRequests.removeAll()
        restoredVideoIDs.removeAll()
        deferredRequests.removeAll()
        for task in retryTasks.values { task.cancel() }
        retryTasks.removeAll()
        for id in ids { backend.cancel(videoID: id) }
        releaseCurrentRequest()
        state = .idle
    }

    /// UI acknowledgement only. It cannot discard an active request or retry.
    public func reset() {
        guard currentRequest == nil else { return }
        state = .idle
    }

    private func accepts(_ request: Request) -> Bool {
        currentRequest?.token == request.token
            && store.entry(videoId: request.video.id, kind: .video)?.shouldAutomaticallyResume == true
    }

    private func advanceQueue() {
        guard !isRestoring, currentRequest == nil else { return }
        if let id = restoredVideoIDs.sorted().first,
           let entry = store.entry(videoId: id, kind: .video) {
            currentRequest = Request(video: entry.video, storageLimitMB: restoredStorageLimitMB(), isAutomatic: true)
            state = .downloading(progress: entry.progress)
            return
        }
        while !pendingRequests.isEmpty {
            let request = pendingRequests.removeFirst()
            guard store.entry(videoId: request.video.id, kind: .video)?.shouldAutomaticallyResume == true else { continue }
            currentRequest = request
            lastWasAutomatic = request.isAutomatic
            lastSavedToPhotos = false
            guard store.canStore(additionalBytes: 0, limitBytes: request.limitBytes) else {
                finishFailure(request.video.id, message: PlaylistDownloadError.storageLimit.localizedDescription)
                return
            }
            beginResolution(request)
            return
        }
    }

    private func beginResolution(_ request: Request) {
        guard accepts(request) else { return }
        let strategy: OfflineSourceRequest = request.usesRefreshedFile ? .refreshedFile : .preferred
        let progress = store.entry(videoId: request.video.id, kind: .video)?.progress ?? 0
        state = .fetching
        store.update(videoId: request.video.id, kind: .video, status: .fetching, progress: progress, resumePolicy: .automatic)
        resolverTask?.cancel()
        resolverTask = Task { [weak self] in
            guard let self else { return }
            do {
                let source = try await resolveSource(request.video, strategy)
                try Task.checkCancellation()
                guard accepts(request) else { return }
                switch source.media {
                case .hls(let url): backend.startHLS(video: request.video, url: url, userAgent: source.userAgent)
                case .file(let url): backend.startFile(video: request.video, url: url, userAgent: source.userAgent)
                }
            } catch is CancellationError { return }
            catch {
                guard accepts(request), !Task.isCancelled else { return }
                handleFailure(request.video.id, message: error.localizedDescription, errorCode: (error as NSError).code, httpStatus: nil)
            }
        }
    }

    private func handle(_ event: PlaylistDownloadEvent) {
        guard let entry = store.entry(videoId: event.videoID, kind: .video),
              entry.shouldAutomaticallyResume else { return }
        switch event {
        case .restored(let id, let progress):
            restoredVideoIDs.insert(id)
            store.update(videoId: id, kind: .video, status: .downloading, progress: progress, resumePolicy: .automatic)
        case .progress(let id, let progress):
            store.update(videoId: id, kind: .video, status: .downloading, progress: progress, resumePolicy: .automatic)
            if activeVideoID == id { state = .downloading(progress: progress) }
        case .waiting(let id):
            store.update(videoId: id, kind: .video, status: .reconnecting, progress: entry.progress,
                         errorMessage: "Ожидаем соединение. Скачанные данные сохранены.", resumePolicy: .automatic)
        case .failed(let id, _, let message, let errorCode, let httpStatus):
            handleFailure(id, message: message, errorCode: errorCode, httpStatus: httpStatus)
        case .completed(let id, let location):
            if activeVideoID == id { state = .saving }
            do {
                let bytes = PlaylistDownloadBackend.allocatedSize(at: location)
                let alreadyCounted = location.path.contains("/SmartTubeDownloads/.range-pieces/")
                let limit = currentRequest.flatMap { $0.video.id == id ? $0.limitBytes : nil }
                    ?? Int64(max(256, restoredStorageLimitMB())) * 1_024 * 1_024
                guard store.canStore(additionalBytes: alreadyCounted ? 0 : bytes, limitBytes: limit) else {
                    throw PlaylistDownloadError.storageLimit
                }
                let finalURL = try PlaylistDownloadBackend.preparePermanentLocation(source: location, videoID: id, store: store)
                store.complete(video: entry.video, kind: .video, fileURL: finalURL, fileSizeBytes: bytes)
                lastCompletedKind = .video
                finish(id, result: .done)
            } catch {
                finishFailure(id, message: error.localizedDescription)
            }
        }
    }

    private func handleFailure(_ id: String, message: String, errorCode: Int, httpStatus: Int?) {
        guard let request = currentRequest, request.video.id == id else {
            // Restored native tasks can finish out of order. Preserve their entry
            // and enqueue a new resolver without taking over the selected job.
            restoredVideoIDs.remove(id)
            if let entry = store.entry(videoId: id, kind: .video) {
                store.update(videoId: id, kind: .video, status: .reconnecting, progress: entry.progress,
                             errorMessage: message, resumePolicy: .automatic)
                if !pendingRequests.contains(where: { $0.video.id == id }) {
                    pendingRequests.append(Request(video: entry.video, storageLimitMB: restoredStorageLimitMB(), isAutomatic: true))
                }
            }
            advanceQueue()
            return
        }
        if let delay = PlaylistDownloadPolicy.retryDelay(errorCode: errorCode, httpStatus: httpStatus, attempt: request.retryAttempt) {
            let progress = store.entry(videoId: id, kind: .video)?.progress ?? 0
            store.update(videoId: id, kind: .video, status: .reconnecting, progress: progress,
                         errorMessage: "Соединение прервано. Повторим автоматически с доступной точки восстановления.",
                         resumePolicy: .automatic)
            var retry = request
            if networkAvailable { retry.retryAttempt += 1 }
            deferredRequests[id] = retry
            restoredVideoIDs.remove(id)
            releaseCurrentRequest()
            state = .idle
            if networkAvailable {
                retryTasks[id]?.cancel()
                retryTasks[id] = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                    self?.enqueueDeferredRequest(id, token: request.token)
                }
            }
            advanceQueue()
        } else if !request.usesRefreshedFile {
            var refreshed = request
            refreshed.usesRefreshedFile = true
            currentRequest = refreshed
            beginResolution(refreshed)
        } else {
            finishFailure(id, message: message)
        }
    }

    private func enqueueDeferredRequest(_ id: String, token: UUID) {
        guard let request = deferredRequests[id], request.token == token else { return }
        retryTasks.removeValue(forKey: id)
        guard networkAvailable else { return }
        deferredRequests.removeValue(forKey: id)
        guard store.entry(videoId: id, kind: .video)?.shouldAutomaticallyResume == true else { return }
        pendingRequests.append(request)
        advanceQueue()
    }

    private func finishFailure(_ id: String, message: String) {
        let progress = store.entry(videoId: id, kind: .video)?.progress ?? 0
        store.update(videoId: id, kind: .video, status: .failed, progress: progress,
                     errorMessage: message, resumePolicy: .manual)
        finish(id, result: .failed(message))
    }

    private func finish(_ id: String, result: DownloadState) {
        restoredVideoIDs.remove(id)
        if activeVideoID == id {
            releaseCurrentRequest()
            state = result
        }
        // A toast can acknowledge state synchronously. Neither it nor an older
        // completion owns the next request.
        Task { @MainActor [weak self] in
            await Task.yield()
            self?.advanceQueue()
        }
    }

    private func releaseCurrentRequest() {
        resolverTask?.cancel()
        resolverTask = nil
        currentRequest = nil
    }

    private func restoreTransfers() {
        guard !isRestoring else { return }
        isRestoring = true
        backend.restoreTasks { [weak self] ids in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let eligible = Set(store.automaticallyResumableEntries.filter { $0.kind == .video }.map(\.videoId))
                for id in ids.subtracting(eligible) { backend.cancel(videoID: id) }
                restoredVideoIDs.formUnion(ids.intersection(eligible))
                // A task may have completed before this callback reached MainActor.
                restoredVideoIDs.formIntersection(eligible)
                for entry in store.automaticallyResumableEntries where entry.kind == .video {
                    guard entry.videoId != activeVideoID, !restoredVideoIDs.contains(entry.videoId),
                          deferredRequests[entry.videoId] == nil,
                          !pendingRequests.contains(where: { $0.video.id == entry.videoId }) else { continue }
                    pendingRequests.append(Request(video: entry.video, storageLimitMB: restoredStorageLimitMB(), isAutomatic: true))
                }
                pendingRequests.removeAll { restoredVideoIDs.contains($0.video.id) }
                isRestoring = false
                advanceQueue()
            }
        }
    }

    private func observeLifecycle() {
        let monitor = NWPathMonitor()
        networkMonitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            let available = path.status == .satisfied
            Task { @MainActor [weak self] in
                guard let self else { return }
                networkAvailable = available
                if available {
                    for request in Array(deferredRequests.values) where retryTasks[request.video.id] == nil {
                        enqueueDeferredRequest(request.video.id, token: request.token)
                    }
                }
            }
        }
        monitor.start(queue: DispatchQueue(label: "AxrTube.Offline.Network"))
        #if canImport(UIKit)
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                store.reconcileLocalFiles()
                if currentRequest == nil { restoreTransfers() }
            }
        }
        maintenanceTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
                guard let self else { return }
                if UIApplication.shared.applicationState == .active { store.reconcileLocalFiles() }
            }
        }
        #endif
    }

    public func prioritizePlayback(_ player: AVPlayer, preparing: Bool) {
        playbackPreparing = preparing
        if observedPlayer !== player {
            observedPlayer = player
            playbackObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.updatePlaybackPriority() }
            }
        }
        updatePlaybackPriority()
    }

    private func updatePlaybackPriority() {
        setPlaybackDemand(preparing: playbackPreparing,
                          waiting: observedPlayer?.timeControlStatus == .waitingToPlayAtSpecifiedRate)
    }

    func setPlaybackDemand(preparing: Bool, waiting: Bool) {
        let pressured = PlaylistDownloadPolicy.shouldYieldToPlayback(preparing: preparing, waitingForBuffer: waiting)
        if !pressured {
            pressureEpisodeActive = false
            pressureReleaseTask?.cancel()
            backend.setPlaybackPressure(false)
        } else if !pressureEpisodeActive {
            pressureEpisodeActive = true
            backend.setPlaybackPressure(true)
            pressureReleaseTask = Task { [weak self, playbackGracePeriod] in
                do { try await Task.sleep(for: playbackGracePeriod) } catch { return }
                // A loading/buffering spinner must not hold the offline queue forever.
                self?.backend.setPlaybackPressure(false)
            }
        }
    }
}
