import Foundation
import Observation

public enum OfflineMediaKind: String, Codable, CaseIterable, Sendable {
    case video
    case audio

    public var fileExtension: String {
        switch self {
        case .video: "mp4"
        case .audio: "m4a"
        }
    }
}

public enum OfflineDownloadStatus: String, Codable, Sendable {
    case queued
    case fetching
    case downloading
    case saving
    case reconnecting
    case waitingForWiFi
    case paused
    case finalizationPending
    case completed
    case failed
    case cancelled

    public var isActive: Bool {
        self == .queued || self == .fetching || self == .downloading || self == .saving
            || self == .reconnecting || self == .waitingForWiFi
    }

    public var isResumable: Bool {
        isActive || self == .paused || self == .finalizationPending
            || self == .failed || self == .cancelled
    }
}

/// Distinguishes an explicit user pause from an interruption that the app must
/// reconcile automatically. The default is intentionally automatic so older
/// manifests created before this field existed do not become permanently stuck.
public enum DownloadResumePolicy: String, Codable, Sendable {
    case automatic
    case manual
}

/// Durable, typed reasons for terminal offline failures whose recovery is not a
/// blind retry. The optional field keeps older manifests source-compatible.
public enum OfflineFailureReason: String, Codable, Sendable {
    /// Compatibility value written by the previous combined age/login classifier.
    /// It is intentionally retryable because the original evidence was ambiguous.
    case signInRequired
    case ageRestricted
    case loginRequired
    case botChallenge
    case regionRestricted
    case unavailable
    case transientNetwork
    case resolverFailure
}

public enum OfflineFailurePresentationPolicy {
    public static func reason(for error: Error) -> OfflineFailureReason? {
        if let apiError = error as? APIError {
            switch apiError {
            case .ageRestricted:
                return .ageRestricted
            case .signInRequired, .notAuthenticated:
                return .loginRequired
            case .ipBlocked:
                return .botChallenge
            case .regionRestricted:
                return .regionRestricted
            case .unavailable:
                return .unavailable
            case .httpError(let status):
                if status == 401 { return .loginRequired }
                if status == 404 { return .unavailable }
                return status == 429 ? .botChallenge : .resolverFailure
            case .decodingError, .invalidURL:
                return .resolverFailure
            }
        }

        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return .transientNetwork
        }
        if nsError.domain == AudioSourceResolutionFailure.errorDomain {
            return .resolverFailure
        }
        return inferredReason(from: error.localizedDescription)
    }

    public static func inferredReason(from message: String?) -> OfflineFailureReason? {
        guard let message else { return nil }
        let value = message.lowercased()
        if value.contains("age-restricted or requires sign in") {
            return .signInRequired
        }
        if ["age-restricted", "age restricted", "age verification", "confirm your age"]
            .contains(where: value.contains) {
            return .ageRestricted
        }
        if ["not a bot", "confirm you're not", "your ip", "ip address", "vpn", "proxy"]
            .contains(where: value.contains) {
            return .botChallenge
        }
        if ["not available in your country", "not available in your region", "region restriction"]
            .contains(where: value.contains) {
            return .regionRestricted
        }
        if value.contains("sign in") || value.contains("not authenticated") {
            return .loginRequired
        }
        if value.contains("video is unavailable") || value.contains("video unavailable") {
            return .unavailable
        }
        return nil
    }

    public static func message(for reason: OfflineFailureReason) -> String {
        switch reason {
        case .signInRequired:
            return "YouTube не подтвердил доступ. Повторите попытку."
        case .ageRestricted:
            return "Нужно подтвердить возраст в YouTube."
        case .loginRequired:
            return "Для ролика нужен вход в YouTube."
        case .botChallenge:
            return "YouTube просит проверить запрос. Повторите попытку."
        case .regionRestricted:
            return "Ролик недоступен в вашем регионе."
        case .unavailable:
            return "Ролик недоступен у источника."
        case .transientNetwork:
            return "Сеть временно недоступна. Повторите попытку."
        case .resolverFailure:
            return "Источник аудио временно недоступен."
        }
    }

    public static func allowsManualRetry(for reason: OfflineFailureReason?) -> Bool {
        switch reason {
        case .ageRestricted, .loginRequired, .regionRestricted, .unavailable:
            return false
        case .signInRequired, .botChallenge, .transientNetwork, .resolverFailure, nil:
            return true
        }
    }
}

/// One item in iPocketTube's internal offline collection. The historical type name
/// is retained so existing manifests decode in place, but entries can now contain
/// either video (MP4) or audio (M4A) and persist download lifecycle state.
public struct DownloadedVideo: Codable, Sendable, Identifiable {
    public var id: String { "\(videoId)::\(kind.rawValue)" }
    public let videoId: String
    public let title: String
    public let channelTitle: String
    public let thumbnailURL: URL?
    public let duration: Double
    public let fileURL: URL
    /// Successful local finalization time. `nil` means no trustworthy evidence.
    public var downloadedAt: Date?
    /// Updated only for a user-selected playback activation, never by progress,
    /// interruption recovery, periodic observers, or background auto-resume.
    public var lastPlayedAt: Date?
    public let kind: OfflineMediaKind
    public var status: OfflineDownloadStatus
    public var progress: Double
    public var fileSizeBytes: Int64
    public var errorMessage: String?
    public var failureReason: OfflineFailureReason?
    public var retryCount: Int
    public var resumePolicy: DownloadResumePolicy

    public init(
        videoId: String,
        title: String,
        channelTitle: String,
        thumbnailURL: URL?,
        duration: Double,
        fileURL: URL,
        downloadedAt: Date?,
        lastPlayedAt: Date? = nil,
        kind: OfflineMediaKind = .video,
        status: OfflineDownloadStatus = .completed,
        progress: Double = 1,
        fileSizeBytes: Int64 = 0,
        errorMessage: String? = nil,
        failureReason: OfflineFailureReason? = nil,
        retryCount: Int = 0,
        resumePolicy: DownloadResumePolicy = .automatic
    ) {
        self.videoId = videoId
        self.title = title
        self.channelTitle = channelTitle
        self.thumbnailURL = thumbnailURL
        self.duration = duration
        self.fileURL = fileURL
        self.downloadedAt = downloadedAt
        self.lastPlayedAt = lastPlayedAt
        self.kind = kind
        self.status = status
        self.progress = min(max(progress, 0), 1)
        self.fileSizeBytes = fileSizeBytes
        self.errorMessage = errorMessage
        self.failureReason = failureReason
        self.retryCount = retryCount
        self.resumePolicy = resumePolicy
    }

    public var shouldAutomaticallyResume: Bool {
        guard kind == .audio, resumePolicy == .automatic else { return false }
        return status.isActive || status == .paused || status == .finalizationPending
    }

    public var video: Video {
        var value = Video(
            id: videoId,
            title: title,
            channelTitle: channelTitle,
            thumbnailURL: thumbnailURL,
            duration: duration
        )
        value.localFileURL = fileURL
        value.localMediaKind = kind
        return value
    }

    private enum CodingKeys: String, CodingKey {
        case videoId, title, channelTitle, thumbnailURL, duration, fileURL, downloadedAt, lastPlayedAt
        case kind, status, progress, fileSizeBytes, errorMessage, failureReason, retryCount, resumePolicy
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        videoId = try container.decode(String.self, forKey: .videoId)
        title = try container.decode(String.self, forKey: .title)
        channelTitle = try container.decode(String.self, forKey: .channelTitle)
        thumbnailURL = try container.decodeIfPresent(URL.self, forKey: .thumbnailURL)
        duration = try container.decode(Double.self, forKey: .duration)
        fileURL = try container.decode(URL.self, forKey: .fileURL)
        downloadedAt = try container.decodeIfPresent(Date.self, forKey: .downloadedAt)
        lastPlayedAt = try container.decodeIfPresent(Date.self, forKey: .lastPlayedAt)
        // Defaults migrate the pre-P1 video-only manifest without data loss.
        kind = try container.decodeIfPresent(OfflineMediaKind.self, forKey: .kind) ?? .video
        status = try container.decodeIfPresent(OfflineDownloadStatus.self, forKey: .status) ?? .completed
        progress = try container.decodeIfPresent(Double.self, forKey: .progress) ?? 1
        fileSizeBytes = try container.decodeIfPresent(Int64.self, forKey: .fileSizeBytes) ?? 0
        errorMessage = try container.decodeIfPresent(String.self, forKey: .errorMessage)
        failureReason = try container.decodeIfPresent(OfflineFailureReason.self, forKey: .failureReason)
            ?? OfflineFailurePresentationPolicy.inferredReason(from: errorMessage)
        retryCount = try container.decodeIfPresent(Int.self, forKey: .retryCount) ?? 0
        resumePolicy = try container.decodeIfPresent(DownloadResumePolicy.self, forKey: .resumePolicy)
            ?? (status == .cancelled ? .manual : .automatic)
    }
}

/// Persistent internal media collection with duplicate prevention, lifecycle
/// persistence, explicit storage accounting, and atomic manifest writes.
@Observable
@MainActor
public final class DownloadStore {
    public static let shared = DownloadStore()

    public private(set) var entries: [DownloadedVideo] = []
    public private(set) var isHydrated = false
    private let downloadsDirectory: URL
    private var manifestURL: URL { downloadsDirectory.appendingPathComponent("manifest.json") }

    /// Durable partial media lives beside the manifest rather than in Library/Caches,
    /// because iOS may purge Caches while an item is paused or the app is suspended.
    public var partialDownloadsDirectory: URL {
        downloadsDirectory.appendingPathComponent(".partial", isDirectory: true)
    }

    public init(baseDirectory: URL? = nil) {
        downloadsDirectory = baseDirectory ?? FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            // Legacy on-disk directory retained so existing offline manifests remain addressable.
            .appendingPathComponent("SmartTubeDownloads")
        loadManifest()
    }

    public func destinationURL(
        for videoId: String,
        kind: OfflineMediaKind = .video
    ) -> URL {
        let encoded = videoId.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? videoId
        return downloadsDirectory.appendingPathComponent("\(encoded).\(kind.fileExtension)")
    }

    public var completedSizeBytes: Int64 {
        entries.reduce(into: 0) { total, entry in
            guard entry.status == .completed else { return }
            if entry.fileSizeBytes > 0 {
                total += entry.fileSizeBytes
            } else if let bytes = try? entry.fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += Int64(bytes)
            }
        }
    }

    /// Actual bytes owned by unfinished sparse caches. This is derived from the
    /// atomically persisted verified range maps, never from a volatile UI value
    /// or the sparse file's logical length.
    public var partialSizeBytes: Int64 {
        partialSnapshots().reduce(0) { $0 + $1.allocatedBytes }
    }

    /// Storage UI and the storage cap must include both final assets and durable
    /// partial/in-flight caches. A failed export can therefore never look like 0 KB.
    public var totalSizeBytes: Int64 { completedSizeBytes + partialSizeBytes }

    public func entry(videoId: String, kind: OfflineMediaKind) -> DownloadedVideo? {
        entries.first { $0.videoId == videoId && $0.kind == kind }
    }

    public func containsCompleted(videoId: String, kind: OfflineMediaKind) -> Bool {
        entry(videoId: videoId, kind: kind)?.status == .completed
    }

    @discardableResult
    public func begin(video: Video, kind: OfflineMediaKind) -> Bool {
        if let index = entries.firstIndex(where: { $0.videoId == video.id && $0.kind == kind }) {
            if entries[index].status == .completed || entries[index].status.isActive {
                return false
            }
            // A retry/relaunch continues the same logical item and preserves its
            // verified sparse progress. Fresh stream URLs are resolved by the caller.
            entries[index].status = .queued
            entries[index].errorMessage = nil
            entries[index].failureReason = nil
            entries[index].retryCount += 1
            entries[index].resumePolicy = .automatic
            if kind == .audio, let partial = bestPartialSnapshot(videoID: video.id) {
                entries[index].fileSizeBytes = partial.verifiedBytes
                entries[index].progress = partial.progress
            } else if kind == .audio {
                entries[index].fileSizeBytes = 0
                entries[index].progress = 0
            }
            saveManifest()
            return true
        }
        entries.append(DownloadedVideo(
            videoId: video.id,
            title: video.title,
            channelTitle: video.channelTitle,
            thumbnailURL: video.thumbnailURL,
            duration: video.duration ?? 0,
            fileURL: destinationURL(for: video.id, kind: kind),
            downloadedAt: nil,
            kind: kind,
            status: .queued,
            progress: 0
        ))
        saveManifest()
        return true
    }

    /// A user playback command atomically takes ownership from foreground
    /// reconciliation without deleting verified sparse ranges. Unlike `begin`,
    /// this succeeds for an active persisted job so the first tap after launch
    /// cannot become a no-op while a supervisor is resolving fresh metadata.
    @discardableResult
    public func claimForPlayback(video: Video, kind: OfflineMediaKind) -> Bool {
        if let index = entries.firstIndex(where: { $0.videoId == video.id && $0.kind == kind }) {
            guard entries[index].status != .completed else { return false }
            entries[index].status = .queued
            entries[index].errorMessage = nil
            entries[index].failureReason = nil
            entries[index].resumePolicy = .automatic
            if kind == .audio, let partial = bestPartialSnapshot(videoID: video.id) {
                entries[index].fileSizeBytes = max(entries[index].fileSizeBytes, partial.verifiedBytes)
                entries[index].progress = max(entries[index].progress, partial.progress)
            }
            saveManifest()
            return true
        }
        return begin(video: video, kind: kind)
    }

    public func update(
        videoId: String,
        kind: OfflineMediaKind,
        status: OfflineDownloadStatus,
        progress: Double,
        errorMessage: String? = nil,
        failureReason: OfflineFailureReason? = nil,
        retryCount: Int? = nil,
        fileSizeBytes: Int64? = nil,
        resumePolicy: DownloadResumePolicy? = nil
    ) {
        guard let index = entries.firstIndex(where: {
            $0.videoId == videoId && $0.kind == kind
        }) else { return }
        entries[index].status = status
        // Verified download progress is monotonic for one representation. Resetting
        // happens only in begin() after proving that no compatible range map exists.
        entries[index].progress = max(entries[index].progress, min(max(progress, 0), 1))
        entries[index].errorMessage = errorMessage
        entries[index].failureReason = failureReason
        if let retryCount { entries[index].retryCount = retryCount }
        if let fileSizeBytes {
            entries[index].fileSizeBytes = max(entries[index].fileSizeBytes, fileSizeBytes)
        }
        if let resumePolicy { entries[index].resumePolicy = resumePolicy }
        saveManifest()
    }

    public func markUserPaused(videoId: String, kind: OfflineMediaKind) {
        guard let entry = entry(videoId: videoId, kind: kind) else { return }
        update(
            videoId: videoId,
            kind: kind,
            status: .paused,
            progress: entry.progress,
            errorMessage: "Download paused by you.",
            resumePolicy: .manual
        )
    }

    public func markAutomaticRecoveryPending(videoId: String, kind: OfflineMediaKind) {
        guard let entry = entry(videoId: videoId, kind: kind), entry.status != .completed else { return }
        update(
            videoId: videoId,
            kind: kind,
            status: .reconnecting,
            progress: entry.progress,
            errorMessage: "Resuming automatically…",
            resumePolicy: .automatic
        )
    }

    public var automaticallyResumableEntries: [DownloadedVideo] {
        entries.filter(\.shouldAutomaticallyResume)
    }

    public func complete(
        video: Video,
        kind: OfflineMediaKind,
        fileURL: URL,
        fileSizeBytes: Int64
    ) {
        let existing = entry(videoId: video.id, kind: kind)
        let completionDate = existing?.status == .completed
            ? existing?.downloadedAt
            : Date()
        entries.removeAll { $0.videoId == video.id && $0.kind == kind }
        entries.append(DownloadedVideo(
            videoId: video.id,
            title: video.title,
            channelTitle: video.channelTitle,
            thumbnailURL: video.thumbnailURL,
            duration: video.duration ?? 0,
            fileURL: fileURL,
            downloadedAt: completionDate,
            lastPlayedAt: existing?.lastPlayedAt,
            kind: kind,
            status: .completed,
            progress: 1,
            fileSizeBytes: fileSizeBytes
        ))
        saveManifest()
    }

    public func markPlaybackActivated(
        videoId: String,
        kind: OfflineMediaKind,
        at date: Date = Date()
    ) {
        guard let index = entries.firstIndex(where: {
            $0.videoId == videoId && $0.kind == kind
        }) else { return }
        entries[index].lastPlayedAt = date
        saveManifest()
    }

    /// Backward-compatible completed-video registration.
    public func add(_ entry: DownloadedVideo) {
        entries.removeAll { $0.videoId == entry.videoId && $0.kind == entry.kind }
        entries.append(entry)
        saveManifest()
    }

    public func canStore(additionalBytes: Int64, limitBytes: Int64) -> Bool {
        limitBytes > 0 && totalSizeBytes + max(0, additionalBytes) <= limitBytes
    }

    public func remove(videoId: String, kind: OfflineMediaKind) {
        if let entry = entry(videoId: videoId, kind: kind) {
            try? FileManager.default.removeItem(at: entry.fileURL)
        }
        entries.removeAll { $0.videoId == videoId && $0.kind == kind }
        removePartialArtifacts(videoId: videoId, kind: kind)
        saveManifest()
    }

    /// Historical API removes every representation of the video.
    public func remove(videoId: String) {
        for entry in entries where entry.videoId == videoId {
            try? FileManager.default.removeItem(at: entry.fileURL)
        }
        entries.removeAll { $0.videoId == videoId }
        for kind in OfflineMediaKind.allCases {
            removePartialArtifacts(videoId: videoId, kind: kind)
        }
        saveManifest()
    }

    public func clearAll() {
        for entry in entries { try? FileManager.default.removeItem(at: entry.fileURL) }
        try? FileManager.default.removeItem(at: partialDownloadsDirectory)
        entries.removeAll()
        saveManifest()
    }

    private func loadManifest() {
        defer { isHydrated = true }
        guard let data = try? Data(contentsOf: manifestURL),
              let decoded = try? JSONDecoder().decode([DownloadedVideo].self, from: data) else {
            return
        }
        let fileManager = FileManager.default
        entries = decoded.compactMap { stored in
            let expectedURL = destinationURL(for: stored.videoId, kind: stored.kind)
            let actualURL = fileManager.fileExists(atPath: stored.fileURL.path)
                ? stored.fileURL
                : expectedURL
            let exists = fileManager.fileExists(atPath: actualURL.path)
            let migratedDownloadedAt = stored.downloadedAt
                ?? inferredFinalizationDate(
                    for: actualURL,
                    status: stored.status,
                    fileExists: exists
                )

            var restored = DownloadedVideo(
                videoId: stored.videoId,
                title: stored.title,
                channelTitle: stored.channelTitle,
                thumbnailURL: stored.thumbnailURL,
                duration: stored.duration,
                fileURL: actualURL,
                downloadedAt: migratedDownloadedAt,
                lastPlayedAt: stored.lastPlayedAt,
                kind: stored.kind,
                status: stored.status,
                progress: stored.progress,
                fileSizeBytes: stored.fileSizeBytes,
                errorMessage: stored.errorMessage,
                failureReason: stored.failureReason,
                retryCount: stored.retryCount,
                resumePolicy: stored.resumePolicy
            )
            if restored.status.isActive {
                restored.status = .reconnecting
                restored.errorMessage = "Resuming automatically…"
                restored.resumePolicy = .automatic
            } else if restored.status == .paused, restored.resumePolicy == .automatic {
                // Legacy builds used `.paused` for process termination, source
                // switching, and transient network loss. These were never user
                // pauses, so migrate them into the automatic reconciliation path.
                restored.status = .reconnecting
                restored.errorMessage = "Resuming automatically…"
            } else if restored.status == .completed, !exists {
                // Never make a library row silently disappear. A completed manifest
                // whose file was removed/purged is a recoverable, user-visible state;
                // Retry can resolve a fresh URL while preserving the logical item.
                restored.status = .failed
                restored.progress = 0
                restored.fileSizeBytes = 0
                restored.errorMessage = "Offline file is missing. Tap Retry."
            } else if restored.status != .completed,
                      exists,
                      actualURL.standardizedFileURL == expectedURL.standardizedFileURL,
                      let size = try? actualURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                      size > 0 {
                // Atomic media installation may finish immediately before a
                // process termination and the following manifest commit. The
                // durable final path is authoritative in this narrow window;
                // promote it instead of resolving the network from zero.
                restored.status = .completed
                restored.progress = 1
                restored.fileSizeBytes = Int64(size)
                restored.downloadedAt = restored.downloadedAt
                    ?? inferredFinalizationDate(
                        for: actualURL,
                        status: .completed,
                        fileExists: true
                    )
                restored.errorMessage = nil
                restored.resumePolicy = .automatic
            }
            return restored
        }
        for completed in entries where completed.status == .completed {
            removePartialArtifacts(videoId: completed.videoId, kind: completed.kind)
        }
        reconcilePartialProgress()
        saveManifest()
    }

    private func inferredFinalizationDate(
        for fileURL: URL,
        status: OfflineDownloadStatus,
        fileExists: Bool
    ) -> Date? {
        guard status == .completed, fileExists,
              let values = try? fileURL.resourceValues(forKeys: [
                .creationDateKey,
                .contentModificationDateKey,
              ]) else { return nil }
        let candidate = values.creationDate ?? values.contentModificationDate
        guard let candidate,
              candidate.timeIntervalSince1970 > 978_307_200,
              candidate <= Date().addingTimeInterval(300) else { return nil }
        return candidate
    }

    private struct PartialSnapshot {
        let videoID: String
        let profile: String
        let verifiedBytes: Int64
        let expectedBytes: Int64
        let allocatedBytes: Int64

        var progress: Double {
            guard expectedBytes > 0 else { return 0 }
            return min(1, max(0, Double(verifiedBytes) / Double(expectedBytes)))
        }
    }

    private func partialSnapshots() -> [PartialSnapshot] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: partialDownloadsDirectory,
            includingPropertiesForKeys: nil
        ) else { return [] }
        return files.compactMap { file in
            guard file.lastPathComponent.hasSuffix(".ranges.json"),
                  let data = try? Data(contentsOf: file),
                  let manifest = try? JSONDecoder().decode(SparseCacheManifest.self, from: data),
                  manifest.version == SparseCacheManifest.currentVersion,
                  let expected = manifest.fingerprint.contentLength,
                  expected > 0 else { return nil }
            let verified = min(expected, manifest.index.cachedByteCount)
            let name = file.lastPathComponent
            let cacheName = String(name.dropLast(".ranges.json".count)) + ".part"
            let cacheURL = file.deletingLastPathComponent().appendingPathComponent(cacheName)
            let values = try? cacheURL.resourceValues(forKeys: [
                .fileAllocatedSizeKey,
                .totalFileAllocatedSizeKey,
            ])
            let allocated = Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
            return PartialSnapshot(
                videoID: manifest.fingerprint.videoID,
                profile: manifest.fingerprint.profile,
                verifiedBytes: verified,
                expectedBytes: expected,
                allocatedBytes: allocated > 0 ? allocated : verified
            )
        }
    }

    private func bestPartialSnapshot(videoID: String) -> PartialSnapshot? {
        partialSnapshots()
            .filter { $0.videoID == videoID }
            .max { lhs, rhs in lhs.verifiedBytes < rhs.verifiedBytes }
    }

    private func reconcilePartialProgress() {
        let snapshots = Dictionary(grouping: partialSnapshots(), by: \PartialSnapshot.videoID)
        for index in entries.indices where entries[index].kind == .audio && entries[index].status != .completed {
            guard let best = snapshots[entries[index].videoId]?.max(by: {
                $0.verifiedBytes < $1.verifiedBytes
            }) else { continue }
            entries[index].fileSizeBytes = best.verifiedBytes
            entries[index].progress = max(entries[index].progress, best.progress)
        }
    }

    private func saveManifest() {
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: downloadsDirectory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: manifestURL, options: .atomic)
    }

    private func removePartialArtifacts(videoId: String, kind: OfflineMediaKind) {
        let safeID = videoId.replacingOccurrences(of: "/", with: "_")
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: partialDownloadsDirectory,
            includingPropertiesForKeys: nil
        ) else { return }
        let prefix = "\(safeID)-\(kind.rawValue)-"
        for file in files where file.lastPathComponent.hasPrefix(prefix) {
            try? FileManager.default.removeItem(at: file)
        }
    }
}
