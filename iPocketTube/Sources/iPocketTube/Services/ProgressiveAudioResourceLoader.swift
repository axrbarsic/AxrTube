#if os(iOS)
import AVFoundation
import CryptoKit
import Foundation
import Network
import iPocketTubeCore
import UniformTypeIdentifiers

/// Sparse byte-range cache shared by AVPlayer and the eventual offline asset.
/// Player requests (including a tail `moov` lookup) are served before the
/// background fill, and every received byte is placed once in the same file.
final class ProgressiveAudioResourceLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    struct Source: Sendable {
        let url: URL
        let userAgent: String
        let fingerprint: SparseSourceFingerprint
        let legacyProfile: String?

        init(
            url: URL,
            userAgent: String,
            fingerprint: SparseSourceFingerprint,
            legacyProfile: String? = nil
        ) {
            self.url = url
            self.userAgent = userAgent
            self.fingerprint = fingerprint
            self.legacyProfile = legacyProfile
        }
    }

    struct Progress: Sendable {
        let downloadedBytes: Int64
        let expectedBytes: Int64
        let networkBytes: Int64
        let rangeSupported: Bool?
    }

    struct Diagnostic: Sendable {
        let stage: String
        let elapsedMilliseconds: Int
        let statusCode: Int?
        let contentType: String?
        let contentEncoding: String?
        let bodyClass: String?
        let requestedOffset: Int64?
        let byteCount: Int64?
        let expectedBytes: Int64?
        let rangeSupported: Bool?
    }

    private struct LegacySidecar: Codable {
        let expectedBytes: Int64
        let mimeType: String
        let index: SparseByteRangeIndex
    }

    private struct FetchResult: Sendable {
        let data: Data
        let statusCode: Int
        let contentRange: String?
        let contentLength: Int64?
        let entityTag: String?
        let lastModified: String?
        let contentType: String?
        let contentEncoding: String?
        let bodyClass: String
        let refreshedSource: Source?
    }

    private struct InFlightRange {
        let reason: String
        let generation: UInt64
        let task: Task<Void, Never>
    }

    private enum LoaderError: LocalizedError {
        case invalidHTTPStatus(Int)
        case invalidRangeResponse
        case missingContentLength
        case changedRepresentation
        case unexpectedContentType(String)
        case unexpectedContentEncoding(String)

        var errorDescription: String? {
            switch self {
            case .invalidHTTPStatus(let status): "Media server returned HTTP \(status)."
            case .invalidRangeResponse: "Media server returned an invalid byte range."
            case .missingContentLength: "Media server did not report the file size."
            case .changedRepresentation: "The media format changed while resuming the download."
            case .unexpectedContentType(let value): "Media server returned unexpected content type \(value)."
            case .unexpectedContentEncoding(let value): "Media server returned unsupported content encoding \(value)."
            }
        }
    }

    let id: UUID
    private let videoId: String
    private let mimeType: String
    private let fileExtension: String
    private let allowsCellularAccess: Bool
    private let queue: DispatchQueue
    private let session: URLSession
    private let pathMonitor = NWPathMonitor()
    private let cacheURL: URL
    private let sidecarURL: URL
    private let exportAliasURL: URL
    private let startedAt = ContinuousClock.now
    private let refreshSource: @Sendable () async throws -> Source
    private let progressHandler: @Sendable (Progress) -> Void
    private let diagnosticHandler: @Sendable (Diagnostic) -> Void
    private let completionHandler: @Sendable (Result<Progress, Error>) -> Void

    private var source: Source
    private var index = SparseByteRangeIndex()
    private var expectedBytes: Int64 = 0
    private var networkBytes: Int64 = 0
    private var rangeSupported: Bool?
    private var pendingRequests: [AVAssetResourceLoadingRequest] = []
    private var inFlight: [SparseByteRange: InFlightRange] = [:]
    private var requestSet = SparseByteRangeRequestSet()
    private var requestGenerationGate = SparseRangeRequestGenerationGate()
    private var isCancelled = false
    private var isTerminal = false
    private var isComplete = false
    private var didReportCompletion = false
    private var backgroundFillEnabled = false
    private var readURL: URL
    private var networkPath: NWPath?
    private var verifiedChunks: [VerifiedSparseChunk] = []
    private var retryCount = 0
    private var requiresRestoredCacheValidation = false

    init(
        id: UUID,
        source: Source,
        videoId: String,
        mimeType: String,
        fileExtension: String,
        cacheDirectory: URL,
        allowsCellularAccess: Bool,
        refreshSource: @escaping @Sendable () async throws -> Source,
        progress: @escaping @Sendable (Progress) -> Void,
        diagnostic: @escaping @Sendable (Diagnostic) -> Void,
        completion: @escaping @Sendable (Result<Progress, Error>) -> Void
    ) throws {
        self.id = id
        self.source = source
        self.videoId = videoId
        self.mimeType = mimeType
        self.fileExtension = fileExtension
        self.allowsCellularAccess = allowsCellularAccess
        self.refreshSource = refreshSource
        self.progressHandler = progress
        self.diagnosticHandler = diagnostic
        self.completionHandler = completion
        self.queue = DispatchQueue(label: "com.ipockettube.sparse-media.\(videoId)", qos: .userInitiated)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.allowsCellularAccess = allowsCellularAccess
        configuration.allowsExpensiveNetworkAccess = allowsCellularAccess
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: configuration)

        let directory = cacheDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let safeID = videoId.replacingOccurrences(of: "/", with: "_")
        let profileKey = Self.shortHash(source.fingerprint.profile)
        let cacheStem = "\(safeID)-audio-\(profileKey)"
        self.cacheURL = directory.appendingPathComponent("\(cacheStem).\(fileExtension).part")
        self.sidecarURL = directory.appendingPathComponent("\(cacheStem).\(fileExtension).ranges.json")
        // AVFoundation uses the path extension while opening a completed local
        // export source. A hard-link alias keeps one set of bytes but exposes the
        // real media extension instead of the internal `.part` suffix.
        self.exportAliasURL = directory.appendingPathComponent("\(cacheStem).export.\(fileExtension)")
        self.readURL = cacheURL
        super.init()

        migrateLegacyCacheIfNeeded(safeID: safeID)
        if FileManager.default.fileExists(atPath: cacheURL.path),
           let data = try? Data(contentsOf: sidecarURL),
           restoreManifest(data: data) {
            // restoreManifest populated the verified range index.
        } else {
            try? FileManager.default.removeItem(at: cacheURL)
            try? FileManager.default.removeItem(at: sidecarURL)
            FileManager.default.createFile(atPath: cacheURL.path, contents: nil)
        }

        pathMonitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            self.queue.async { [weak self] in
                guard let self, !self.isCancelled, !self.isTerminal else { return }
                self.networkPath = path
                self.emitDiagnostic(stage: self.networkPermitsTransfer ? "network-ready" : "waiting-wifi")
                if self.networkPermitsTransfer {
                    self.processPendingRequests()
                    self.fillNextBackgroundRange()
                }
            }
        }
        pathMonitor.start(queue: queue)
    }

    func makeAsset() -> AVURLAsset {
        let customURL = URL(string: "ipockettube-sparse-cache:///\(videoId).\(fileExtension)")!
        let asset = AVURLAsset(url: customURL)
        asset.resourceLoader.setDelegate(self, queue: queue)
        return asset
    }

    /// Starts only the two-byte metadata probe. AVPlayer's own random requests
    /// stay ahead of background completion so `moov`/index bytes arrive quickly.
    func start() {
        queue.async { [weak self] in
            guard let self, !self.isCancelled, !self.isTerminal else { return }
            // Restore UI state before touching the network. A complete durable
            // range map proceeds directly to finalization on Retry/relaunch.
            self.reportProgress()
            if self.requiresRestoredCacheValidation {
                self.validateRestoredCache()
            } else {
                self.resumeAfterCacheValidation()
            }
        }
    }

    func startBackgroundFill(after delay: Duration = .milliseconds(750)) {
        queue.asyncAfter(deadline: .now() + delay.timeInterval) { [weak self] in
            guard let self, !self.isCancelled else { return }
            self.backgroundFillEnabled = true
            self.fillNextBackgroundRange()
        }
    }

    func cancel(discardCache: Bool = false) {
        queue.sync { [weak self] in
            guard let self, !self.isCancelled else { return }
            self.isCancelled = true
            for request in self.inFlight.values { request.task.cancel() }
            self.inFlight.removeAll()
            self.requestSet.removeAll()
            self.requestGenerationGate.invalidateAll()
            let error = CancellationError()
            for request in self.pendingRequests { request.finishLoading(with: error) }
            self.pendingRequests.removeAll()
            if discardCache {
                try? FileManager.default.removeItem(at: self.cacheURL)
                try? FileManager.default.removeItem(at: self.sidecarURL)
            }
            try? FileManager.default.removeItem(at: self.exportAliasURL)
            self.pathMonitor.cancel()
        }
    }

    func completedSourceURL() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [weak self] in
                guard let self, self.isComplete, !self.isTerminal else {
                    continuation.resume(throwing: URLError(.resourceUnavailable))
                    return
                }
                do {
                    try? FileManager.default.removeItem(at: self.exportAliasURL)
                    try FileManager.default.linkItem(at: self.readURL, to: self.exportAliasURL)
                    continuation.resume(returning: self.exportAliasURL)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func finalize(to destination: URL) async throws -> Int64 {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [weak self] in
                guard let self, self.isComplete, self.expectedBytes > 0 else {
                    continuation.resume(throwing: URLError(.zeroByteResource))
                    return
                }
                do {
                    try FileManager.default.createDirectory(
                        at: destination.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    let staging = destination.appendingPathExtension("new")
                    try? FileManager.default.removeItem(at: staging)
                    do {
                        try FileManager.default.linkItem(at: self.readURL, to: staging)
                    } catch {
                        try FileManager.default.copyItem(at: self.readURL, to: staging)
                    }
                    if FileManager.default.fileExists(atPath: destination.path) {
                        _ = try FileManager.default.replaceItemAt(
                            destination,
                            withItemAt: staging,
                            backupItemName: nil,
                            options: .usingNewMetadataOnly
                        )
                    } else {
                        try FileManager.default.moveItem(at: staging, to: destination)
                    }
                    self.readURL = destination
                    try? FileManager.default.removeItem(at: self.cacheURL)
                    try? FileManager.default.removeItem(at: self.sidecarURL)
                    try? FileManager.default.removeItem(at: self.exportAliasURL)
                    continuation.resume(returning: self.expectedBytes)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        pendingRequests.append(loadingRequest)
        processPendingRequests()
        return true
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {
        pendingRequests.removeAll { $0 === loadingRequest }
    }

    private func processPendingRequests() {
        guard !isCancelled, !isTerminal, !requiresRestoredCacheValidation else { return }
        var finished: [AVAssetResourceLoadingRequest] = []

        for request in pendingRequests {
            if let info = request.contentInformationRequest, expectedBytes > 0 {
                let baseMIMEType = String(mimeType.split(separator: ";", maxSplits: 1)[0])
                info.contentType = UTType(mimeType: baseMIMEType)?.identifier
                    ?? UTType.data.identifier
                info.contentLength = expectedBytes
                info.isByteRangeAccessSupported = rangeSupported ?? true
            }

            guard let dataRequest = request.dataRequest else {
                if expectedBytes > 0 {
                    request.finishLoading()
                    finished.append(request)
                } else {
                    requestRange(SparseByteRange(0, 2), reason: "content-info")
                }
                continue
            }

            guard expectedBytes > 0 else {
                requestRange(SparseByteRange(0, 2), reason: "content-info")
                continue
            }

            let requestStart = dataRequest.requestedOffset
            let requestedEnd: Int64
            if dataRequest.requestsAllDataToEndOfResource {
                requestedEnd = expectedBytes
            } else {
                requestedEnd = min(expectedBytes, requestStart + Int64(dataRequest.requestedLength))
            }
            var cursor = max(requestStart, dataRequest.currentOffset)

            while cursor < requestedEnd,
                  let cached = index.contiguousCachedRange(startingAt: cursor) {
                let count = Int(min(256 * 1024, min(cached.upperBound, requestedEnd) - cursor))
                guard count > 0, let data = readBytes(offset: cursor, count: count), !data.isEmpty else { break }
                dataRequest.respond(with: data)
                cursor = dataRequest.currentOffset
            }

            if cursor >= requestedEnd {
                request.finishLoading()
                finished.append(request)
            } else {
                let end = min(requestedEnd, cursor + 512 * 1024)
                requestRange(SparseByteRange(cursor, end), reason: cursor > expectedBytes / 2 ? "player-tail" : "player")
            }
        }

        if !finished.isEmpty {
            pendingRequests.removeAll { candidate in finished.contains { $0 === candidate } }
        }
    }

    private func requestRange(_ requested: SparseByteRange, reason: String) {
        guard !isCancelled, !isTerminal, !requiresRestoredCacheValidation, !requested.isEmpty else { return }
        guard networkPermitsTransfer else {
            emitDiagnostic(stage: "waiting-wifi", requested: requested)
            return
        }
        let clamped = expectedBytes > 0
            ? SparseByteRange(requested.lowerBound, min(requested.upperBound, expectedBytes))
            : requested
        guard !clamped.isEmpty else { return }

        let playerPriority = reason.hasPrefix("player") || reason == "content-info" || reason == "probe"
        if playerPriority {
            // A seek/play request preempts an overlapping background fill. The
            // reservation is released immediately so AVPlayer never waits behind
            // best-effort sequential completion.
            let overlappingBackground = inFlight.filter {
                $0.key.intersects(clamped) && $0.value.reason == "background-fill"
            }
            for (range, request) in overlappingBackground {
                request.task.cancel()
                inFlight[range] = nil
                requestSet.remove(range)
                requestGenerationGate.invalidate(range)
            }
            if inFlight.count >= 3,
               let background = inFlight.first(where: { $0.value.reason == "background-fill" }) {
                background.value.task.cancel()
                inFlight[background.key] = nil
                requestSet.remove(background.key)
                requestGenerationGate.invalidate(background.key)
            }
        }
        guard inFlight.count < 3 else { return }
        guard requestSet.reserve(clamped, cached: index) else { return }

        emitDiagnostic(stage: reason, requested: clamped)
        let sourceSnapshot = source
        let requestGeneration = requestGenerationGate.issue(for: clamped)
        let task = Task { [weak self] in
            guard let self else { return }
            var attempt = 0
            while !Task.isCancelled {
                if !(await self.networkIsPermitted()) {
                    self.queue.async { [weak self] in
                        self?.emitDiagnostic(stage: "waiting-wifi", requested: clamped)
                    }
                    try? await Task.sleep(for: .seconds(1))
                    continue
                }
                do {
                    let result = try await self.fetch(clamped, source: sourceSnapshot, permitRefresh: true)
                    self.queue.async { [weak self] in
                        self?.receive(result, requested: clamped, generation: requestGeneration)
                    }
                    return
                } catch is CancellationError {
                    return
                } catch {
                    let failure = Self.classify(error)
                    guard SparseDownloadRetryPolicy.shouldRetry(
                        failure: failure,
                        attempt: attempt
                    ) else {
                        self.queue.async { [weak self] in
                            self?.failRange(clamped, generation: requestGeneration, error: error)
                        }
                        return
                    }
                    attempt += 1
                    let delay = SparseDownloadRetryPolicy.delayMilliseconds(
                        attempt: attempt - 1,
                        seed: clamped.lowerBound
                    )
                    self.queue.async { [weak self] in
                        guard let self else { return }
                        self.retryCount += 1
                        self.persistSidecar()
                        self.emitDiagnostic(stage: "retry-backoff-\(delay)ms", requested: clamped)
                    }
                    try? await Task.sleep(for: .milliseconds(delay))
                }
            }
        }
        inFlight[clamped] = InFlightRange(
            reason: reason,
            generation: requestGeneration,
            task: task
        )
    }

    private func fetch(_ range: SparseByteRange, source: Source, permitRefresh: Bool) async throws -> FetchResult {
        var request = URLRequest(url: source.url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(source.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("bytes=\(range.lowerBound)-\(range.upperBound - 1)", forHTTPHeaderField: "Range")
        if let entityTag = source.fingerprint.entityTag {
            request.setValue(entityTag, forHTTPHeaderField: "If-Range")
        } else if let lastModified = source.fingerprint.lastModified {
            request.setValue(lastModified, forHTTPHeaderField: "If-Range")
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        let responseContentType = http.value(forHTTPHeaderField: "Content-Type")
        let responseContentEncoding = http.value(forHTTPHeaderField: "Content-Encoding")
        let normalizedContentType = SparseHTTPMediaResponsePolicy.normalizedContentType(responseContentType)
        let encodingClass = SparseHTTPMediaResponsePolicy.encodingClass(responseContentEncoding)
        let bodyClass = SparseHTTPMediaResponsePolicy.bodyClass(
            contentType: responseContentType,
            byteCount: data.count
        )

        if permitRefresh, [401, 403, 410].contains(http.statusCode) {
            let refreshed = try await refreshSource()
            guard source.fingerprint.isCompatible(with: refreshed.fingerprint) else {
                throw LoaderError.changedRepresentation
            }
            let retried = try await fetch(range, source: refreshed, permitRefresh: false)
            return FetchResult(
                data: retried.data,
                statusCode: retried.statusCode,
                contentRange: retried.contentRange,
                contentLength: retried.contentLength,
                entityTag: retried.entityTag,
                lastModified: retried.lastModified,
                contentType: retried.contentType,
                contentEncoding: retried.contentEncoding,
                bodyClass: retried.bodyClass,
                refreshedSource: refreshed
            )
        }
        guard http.statusCode == 206 || http.statusCode == 200 else {
            emitDiagnostic(
                stage: "http-response-rejected",
                statusCode: http.statusCode,
                byteCount: Int64(data.count),
                contentType: normalizedContentType,
                contentEncoding: encodingClass,
                bodyClass: bodyClass
            )
            throw LoaderError.invalidHTTPStatus(http.statusCode)
        }
        if !SparseHTTPMediaResponsePolicy.acceptsContentEncoding(responseContentEncoding) {
            emitDiagnostic(
                stage: "http-encoding-rejected",
                statusCode: http.statusCode,
                byteCount: Int64(data.count),
                contentType: normalizedContentType,
                contentEncoding: encodingClass,
                bodyClass: bodyClass
            )
            if permitRefresh {
                let refreshed = try await refreshSource()
                guard source.fingerprint.isCompatible(with: refreshed.fingerprint) else {
                    throw LoaderError.changedRepresentation
                }
                let retried = try await fetch(range, source: refreshed, permitRefresh: false)
                return FetchResult(
                    data: retried.data,
                    statusCode: retried.statusCode,
                    contentRange: retried.contentRange,
                    contentLength: retried.contentLength,
                    entityTag: retried.entityTag,
                    lastModified: retried.lastModified,
                    contentType: retried.contentType,
                    contentEncoding: retried.contentEncoding,
                    bodyClass: retried.bodyClass,
                    refreshedSource: refreshed
                )
            }
            throw LoaderError.unexpectedContentEncoding(encodingClass)
        }
        if !SparseHTTPMediaResponsePolicy.acceptsContentType(expected: mimeType, response: responseContentType) {
            emitDiagnostic(
                stage: "http-content-type-rejected",
                statusCode: http.statusCode,
                byteCount: Int64(data.count),
                contentType: normalizedContentType,
                contentEncoding: encodingClass,
                bodyClass: bodyClass
            )
            if permitRefresh {
                let refreshed = try await refreshSource()
                guard source.fingerprint.isCompatible(with: refreshed.fingerprint) else {
                    throw LoaderError.changedRepresentation
                }
                let retried = try await fetch(range, source: refreshed, permitRefresh: false)
                return FetchResult(
                    data: retried.data,
                    statusCode: retried.statusCode,
                    contentRange: retried.contentRange,
                    contentLength: retried.contentLength,
                    entityTag: retried.entityTag,
                    lastModified: retried.lastModified,
                    contentType: retried.contentType,
                    contentEncoding: retried.contentEncoding,
                    bodyClass: retried.bodyClass,
                    refreshedSource: refreshed
                )
            }
            throw LoaderError.unexpectedContentType(normalizedContentType ?? "missing")
        }
        return FetchResult(
            data: data,
            statusCode: http.statusCode,
            contentRange: http.value(forHTTPHeaderField: "Content-Range"),
            contentLength: http.expectedContentLength > 0 ? http.expectedContentLength : nil,
            entityTag: http.value(forHTTPHeaderField: "ETag"),
            lastModified: http.value(forHTTPHeaderField: "Last-Modified"),
            contentType: normalizedContentType,
            contentEncoding: encodingClass,
            bodyClass: bodyClass,
            refreshedSource: nil
        )
    }

    /// A persisted cache is never exposed to AVPlayer solely because its sidecar
    /// decodes. The CDN must confirm the same entity (If-Range when available),
    /// and the probe bytes must match the locally hashed representation first.
    private func validateRestoredCache() {
        guard requiresRestoredCacheValidation, expectedBytes > 0, index.cachedByteCount > 0,
              !isCancelled, !isTerminal else {
            requiresRestoredCacheValidation = false
            resumeAfterCacheValidation()
            return
        }
        guard networkPermitsTransfer else {
            emitDiagnostic(stage: "waiting-wifi")
            queue.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.validateRestoredCache()
            }
            return
        }

        let probe = SparseByteRange(0, min(2, expectedBytes))
        emitDiagnostic(stage: "cache-validator-probe", requested: probe)
        let sourceSnapshot = source
        let requestGeneration = requestGenerationGate.issue(for: probe)
        let task = Task { [weak self] in
            guard let self else { return }
            var attempt = 0
            while !Task.isCancelled {
                do {
                    let result = try await self.fetch(probe, source: sourceSnapshot, permitRefresh: true)
                    self.queue.async { [weak self] in
                        self?.receiveCacheValidation(
                            result,
                            requested: probe,
                            generation: requestGeneration
                        )
                    }
                    return
                } catch is CancellationError {
                    return
                } catch {
                    let failure = Self.classify(error)
                    guard SparseDownloadRetryPolicy.shouldRetry(
                        failure: failure,
                        attempt: attempt
                    ) else {
                        self.queue.async { [weak self] in
                            self?.failRange(probe, generation: requestGeneration, error: error)
                        }
                        return
                    }
                    attempt += 1
                    let delay = SparseDownloadRetryPolicy.delayMilliseconds(
                        attempt: attempt - 1,
                        seed: probe.lowerBound
                    )
                    self.queue.async { [weak self] in
                        guard let self else { return }
                        self.retryCount += 1
                        self.persistSidecar()
                        self.emitDiagnostic(stage: "validator-retry-\(delay)ms", requested: probe)
                    }
                    try? await Task.sleep(for: .milliseconds(delay))
                }
            }
        }
        inFlight[probe] = InFlightRange(
            reason: "cache-validator",
            generation: requestGeneration,
            task: task
        )
    }

    private func receiveCacheValidation(
        _ result: FetchResult,
        requested: SparseByteRange,
        generation: UInt64
    ) {
        guard requestGenerationGate.consume(generation, for: requested) else { return }
        inFlight[requested] = nil
        guard !isCancelled, !isTerminal, requiresRestoredCacheValidation else { return }
        let activeSource = result.refreshedSource ?? source
        guard let placement = HTTPByteRangeInterpreter.placement(
            statusCode: result.statusCode,
            requested: requested,
            contentRange: result.contentRange,
            contentLength: result.contentLength,
            bodyCount: result.data.count
        ) else {
            emitDiagnostic(stage: "cache-validator-invalid", statusCode: result.statusCode, requested: requested)
            if SparseRestoredCacheResponsePolicy.decide(
                hasValidPlacement: false,
                validatorAccepted: false
            ) == .failPreservingVerifiedCache {
                failSession(LoaderError.invalidRangeResponse)
            }
            return
        }

        let responseFingerprint = SparseSourceFingerprint(
            videoID: activeSource.fingerprint.videoID,
            profile: activeSource.fingerprint.profile,
            mimeType: activeSource.fingerprint.mimeType,
            contentLength: placement.totalLength,
            entityTag: result.entityTag,
            lastModified: result.lastModified
        )
        let cachedProbe = readBytes(offset: placement.storedRange.lowerBound, count: result.data.count)
        let exactPartialMatch = SparseRestoredCacheValidator.accepts(
            cachedProbe: cachedProbe,
            responseProbe: result.data,
            serverReturnedWholeBody: placement.serverReturnedWholeBody,
            cachedFingerprint: source.fingerprint,
            responseFingerprint: responseFingerprint
        )

        let decision = SparseRestoredCacheResponsePolicy.decide(
            hasValidPlacement: true,
            validatorAccepted: exactPartialMatch
        )
        if decision == .resumeVerifiedCache {
            source = Source(
                url: activeSource.url,
                userAgent: activeSource.userAgent,
                fingerprint: responseFingerprint,
                legacyProfile: activeSource.legacyProfile
            )
            requiresRestoredCacheValidation = false
            persistSidecar()
            emitDiagnostic(stage: "cache-validator-pass", statusCode: result.statusCode, requested: requested)
            resumeAfterCacheValidation()
            return
        }

        // A 200 to If-Range, changed validators, length, or probe bytes proves
        // that the old entity cannot be mixed with this response. Reset only now.
        emitDiagnostic(stage: "cache-validator-reset", statusCode: result.statusCode, requested: requested)
        resetCacheForFreshRepresentation(source: Source(
            url: activeSource.url,
            userAgent: activeSource.userAgent,
            fingerprint: SparseSourceFingerprint(
                videoID: activeSource.fingerprint.videoID,
                profile: activeSource.fingerprint.profile,
                mimeType: activeSource.fingerprint.mimeType,
                contentLength: nil,
                entityTag: nil,
                lastModified: nil
            ),
            legacyProfile: activeSource.legacyProfile
        ))
        requiresRestoredCacheValidation = false
        receiveAccepted(result, requested: requested)
    }

    private func resumeAfterCacheValidation() {
        guard !isCancelled, !isTerminal else { return }
        reportProgress()
        processPendingRequests()
        checkCompletion()
        if !isComplete {
            requestRange(SparseByteRange(0, 2), reason: "probe")
            fillNextBackgroundRange()
        }
    }

    private func resetCacheForFreshRepresentation(source: Source) {
        requestGenerationGate.invalidateAll()
        try? FileManager.default.removeItem(at: sidecarURL)
        try? FileManager.default.removeItem(at: exportAliasURL)
        if let handle = try? FileHandle(forWritingTo: cacheURL) {
            try? handle.truncate(atOffset: 0)
            try? handle.close()
        } else {
            try? FileManager.default.removeItem(at: cacheURL)
            FileManager.default.createFile(atPath: cacheURL.path, contents: nil)
        }
        self.source = source
        index = SparseByteRangeIndex()
        verifiedChunks = []
        expectedBytes = 0
        networkBytes = 0
        rangeSupported = nil
        retryCount = 0
        isComplete = false
        didReportCompletion = false
    }

    private func receive(
        _ result: FetchResult,
        requested: SparseByteRange,
        generation: UInt64
    ) {
        guard requestGenerationGate.consume(generation, for: requested) else { return }
        receiveAccepted(result, requested: requested)
    }

    private func receiveAccepted(_ result: FetchResult, requested: SparseByteRange) {
        inFlight[requested] = nil
        requestSet.remove(requested)
        if let refreshed = result.refreshedSource { source = refreshed }
        guard !isCancelled, !isTerminal else { return }
        guard let placement = HTTPByteRangeInterpreter.placement(
            statusCode: result.statusCode,
            requested: requested,
            contentRange: result.contentRange,
            contentLength: result.contentLength,
            bodyCount: result.data.count
        ) else {
            failSession(LoaderError.invalidRangeResponse)
            return
        }

        do {
            if placement.serverReturnedWholeBody {
                // The server ignored Range. Enter one safe sequential response
                // mode and cancel every other offset task before writing at zero.
                for (range, request) in inFlight {
                    request.task.cancel()
                    requestSet.remove(range)
                    requestGenerationGate.invalidate(range)
                }
                inFlight.removeAll()
            }
            let responseFingerprint = SparseSourceFingerprint(
                videoID: source.fingerprint.videoID,
                profile: source.fingerprint.profile,
                mimeType: source.fingerprint.mimeType,
                contentLength: placement.totalLength,
                entityTag: result.entityTag,
                lastModified: result.lastModified
            )
            guard source.fingerprint.isCompatible(with: responseFingerprint) else {
                throw LoaderError.changedRepresentation
            }
            // Verify representation identity before mutating any previously
            // validated bytes. A refreshed but different itag/profile can never
            // overwrite the durable cache for the old representation.
            try write(result.data, at: placement.storedRange.lowerBound)
            networkBytes += Int64(result.data.count)
            index.insert(placement.storedRange)
            expectedBytes = max(expectedBytes, placement.totalLength)
            rangeSupported = placement.supportsByteRanges
            source = Source(
                url: source.url,
                userAgent: source.userAgent,
                fingerprint: responseFingerprint,
                legacyProfile: source.legacyProfile
            )
            try replaceVerifiedChunks(
                intersecting: placement.storedRange,
                insertedData: result.data
            )
            persistSidecar()
            emitDiagnostic(
                stage: networkBytes == Int64(result.data.count) ? "first-response" : "range-response",
                statusCode: result.statusCode,
                requested: placement.storedRange,
                byteCount: Int64(result.data.count),
                contentType: networkBytes == Int64(result.data.count) ? result.contentType : nil,
                contentEncoding: networkBytes == Int64(result.data.count) ? result.contentEncoding : nil,
                bodyClass: networkBytes == Int64(result.data.count) ? result.bodyClass : nil
            )
            reportProgress()

            // MP4/M4A indexes are commonly stored at the end of the file. Fetch
            // that tail immediately after the length probe so AVPlayer never has
            // to wait for a sequential background fill to discover `moov`.
            if networkBytes == Int64(result.data.count),
               expectedBytes > 2,
               placement.supportsByteRanges,
               mimeType.lowercased().contains("mp4") {
                let tailStart = max(2, expectedBytes - 512 * 1024)
                requestRange(SparseByteRange(tailStart, expectedBytes), reason: "moov-tail-prefetch")
            }
            processPendingRequests()
            checkCompletion()
            fillNextBackgroundRange()
        } catch {
            failSession(error)
        }
    }

    private func failRange(
        _ range: SparseByteRange,
        generation: UInt64,
        error: Error
    ) {
        guard requestGenerationGate.consume(generation, for: range) else { return }
        inFlight[range] = nil
        requestSet.remove(range)
        guard !isCancelled, !isTerminal else { return }
        failSession(error)
    }

    /// Ends every AVFoundation continuation after bounded recovery is exhausted,
    /// while preserving the verified cache and sidecar for a later Retry.
    private func failSession(_ error: Error) {
        guard !isCancelled, !isTerminal else { return }
        isTerminal = true
        for request in inFlight.values { request.task.cancel() }
        inFlight.removeAll()
        requestSet.removeAll()
        requestGenerationGate.invalidateAll()
        for request in pendingRequests { request.finishLoading(with: error) }
        pendingRequests.removeAll()
        persistSidecar()
        pathMonitor.cancel()
        finish(with: .failure(error))
    }

    private func fillNextBackgroundRange() {
        guard backgroundFillEnabled, expectedBytes > 0, !isComplete, !isCancelled,
              !isTerminal, !requiresRestoredCacheValidation else { return }
        guard inFlight.count < 2 else { return }
        let whole = SparseByteRange(0, expectedBytes)
        guard let missing = index.missingRanges(in: whole).first else {
            checkCompletion()
            return
        }
        let chunk = SparseByteRange(missing.lowerBound, min(missing.upperBound, missing.lowerBound + 1024 * 1024))
        requestRange(chunk, reason: "background-fill")
    }

    private func checkCompletion() {
        guard expectedBytes > 0, index.contains(SparseByteRange(0, expectedBytes)), !isComplete else { return }
        isComplete = true
        emitDiagnostic(stage: "download-complete", byteCount: index.cachedByteCount)
        finish(with: .success(snapshot()))
    }

    private func reportProgress() {
        progressHandler(snapshot())
    }

    private func snapshot() -> Progress {
        Progress(
            downloadedBytes: index.cachedByteCount,
            expectedBytes: expectedBytes,
            networkBytes: networkBytes,
            rangeSupported: rangeSupported
        )
    }

    private func write(_ data: Data, at offset: Int64) throws {
        let handle = try FileHandle(forUpdating: cacheURL)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        try handle.write(contentsOf: data)
    }

    private func readBytes(offset: Int64, count: Int) -> Data? {
        guard count > 0, let handle = try? FileHandle(forReadingFrom: readURL) else { return nil }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: UInt64(offset))
            return try handle.read(upToCount: count)
        } catch {
            return nil
        }
    }

    private func persistSidecar() {
        guard expectedBytes > 0 else { return }
        let fingerprint = SparseSourceFingerprint(
            videoID: source.fingerprint.videoID,
            profile: source.fingerprint.profile,
            mimeType: source.fingerprint.mimeType,
            contentLength: expectedBytes,
            entityTag: source.fingerprint.entityTag,
            lastModified: source.fingerprint.lastModified
        )
        let manifest = SparseCacheManifest(
            fingerprint: fingerprint,
            index: index,
            verifiedChunks: verifiedChunks,
            rangeSupported: rangeSupported,
            retryCount: retryCount
        )
        if let data = try? JSONEncoder().encode(manifest) {
            try? data.write(to: sidecarURL, options: .atomic)
        }
    }

    /// Re-hashes only the unaffected fragments of an overlapped verified chunk.
    /// This keeps the durable invariant `manifest.index == union(chunks)` without
    /// repeatedly hashing the whole growing file.
    private func replaceVerifiedChunks(
        intersecting insertedRange: SparseByteRange,
        insertedData: Data
    ) throws {
        var replacements: [VerifiedSparseChunk] = []
        for chunk in verifiedChunks {
            guard chunk.range.intersects(insertedRange) else {
                replacements.append(chunk)
                continue
            }
            if chunk.range.lowerBound < insertedRange.lowerBound {
                let prefix = SparseByteRange(chunk.range.lowerBound, insertedRange.lowerBound)
                guard let bytes = readBytesFromDisk(range: prefix) else {
                    throw URLError(.cannotOpenFile)
                }
                replacements.append(VerifiedSparseChunk(range: prefix, digest: Self.digest(bytes)))
            }
            if insertedRange.upperBound < chunk.range.upperBound {
                let suffix = SparseByteRange(insertedRange.upperBound, chunk.range.upperBound)
                guard let bytes = readBytesFromDisk(range: suffix) else {
                    throw URLError(.cannotOpenFile)
                }
                replacements.append(VerifiedSparseChunk(range: suffix, digest: Self.digest(bytes)))
            }
        }
        replacements.append(VerifiedSparseChunk(
            range: insertedRange,
            digest: Self.digest(insertedData)
        ))
        verifiedChunks = replacements.sorted { $0.range < $1.range }
    }

    private var networkPermitsTransfer: Bool {
        guard let networkPath else { return true }
        guard networkPath.status == .satisfied else { return false }
        return allowsCellularAccess || networkPath.usesInterfaceType(.wifi)
    }

    private func networkIsPermitted() async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                continuation.resume(returning: self?.networkPermitsTransfer ?? false)
            }
        }
    }

    private func migrateLegacyCacheIfNeeded(safeID: String) {
        guard !FileManager.default.fileExists(atPath: cacheURL.path) else { return }
        let oldCachesDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            // Legacy cache directory is part of the durable range-manifest contract.
            .appendingPathComponent("AxrTubeSparseMedia", isDirectory: true)
        let candidates: [(URL, URL)] = [
            (
                cacheURL.deletingLastPathComponent().appendingPathComponent("\(safeID)-audio-auto.\(fileExtension).part"),
                cacheURL.deletingLastPathComponent().appendingPathComponent("\(safeID)-audio-auto.\(fileExtension).ranges.json")
            ),
            (
                oldCachesDirectory.appendingPathComponent("\(safeID)-auto.\(fileExtension).part"),
                oldCachesDirectory.appendingPathComponent("\(safeID)-auto.ranges.json")
            ),
        ]
        for (legacyCache, legacySidecar) in candidates {
            guard FileManager.default.fileExists(atPath: legacyCache.path),
                  var data = try? Data(contentsOf: legacySidecar) else { continue }
            let compatible: Bool
            if var manifest = try? JSONDecoder().decode(SparseCacheManifest.self, from: data) {
                let strict = source.fingerprint.isCompatible(with: manifest.fingerprint)
                let legacyProfileMatch = source.legacyProfile.map {
                    $0 == manifest.fingerprint.profile
                } ?? false
                    && source.fingerprint.videoID == manifest.fingerprint.videoID
                    && source.fingerprint.mimeType == manifest.fingerprint.mimeType
                compatible = strict || legacyProfileMatch
                if legacyProfileMatch, !strict {
                    // One-time migration from the pre-itag profile. The selected
                    // current format supplies the stable itag; validators/length
                    // remain those already proven by the old range map.
                    manifest.fingerprint = SparseSourceFingerprint(
                        videoID: source.fingerprint.videoID,
                        profile: source.fingerprint.profile,
                        mimeType: source.fingerprint.mimeType,
                        contentLength: manifest.fingerprint.contentLength,
                        entityTag: manifest.fingerprint.entityTag,
                        lastModified: manifest.fingerprint.lastModified
                    )
                    if let upgraded = try? JSONEncoder().encode(manifest) {
                        data = upgraded
                    }
                }
            } else if let legacy = try? JSONDecoder().decode(LegacySidecar.self, from: data) {
                compatible = legacy.mimeType == mimeType
            } else {
                compatible = false
            }
            guard compatible else { continue }
            do {
                try data.write(to: legacySidecar, options: .atomic)
                try FileManager.default.moveItem(at: legacyCache, to: cacheURL)
                try FileManager.default.moveItem(at: legacySidecar, to: sidecarURL)
                return
            } catch {
                // Preserve the legacy pair intact if atomic migration cannot finish.
                if FileManager.default.fileExists(atPath: cacheURL.path),
                   !FileManager.default.fileExists(atPath: legacyCache.path) {
                    try? FileManager.default.moveItem(at: cacheURL, to: legacyCache)
                }
            }
        }
    }

    private func restoreManifest(data: Data) -> Bool {
        if let manifest = try? JSONDecoder().decode(SparseCacheManifest.self, from: data),
           manifest.version == SparseCacheManifest.currentVersion,
           source.fingerprint.isCompatible(with: manifest.fingerprint),
           validateAndRestore(
               chunks: manifest.verifiedChunks,
               expectedBytes: manifest.fingerprint.contentLength ?? 0
           ) {
            source = Source(
                url: source.url,
                userAgent: source.userAgent,
                fingerprint: manifest.fingerprint,
                legacyProfile: source.legacyProfile
            )
            rangeSupported = manifest.rangeSupported
            retryCount = manifest.retryCount
            requiresRestoredCacheValidation = true
            return true
        }

        // Upgrade the old sidecar without discarding valid bytes: every recorded
        // interval is hashed before it is admitted to the verified range index.
        if let legacy = try? JSONDecoder().decode(LegacySidecar.self, from: data),
           legacy.mimeType == mimeType {
            var upgraded: [VerifiedSparseChunk] = []
            for range in legacy.index.ranges {
                guard let bytes = readBytesFromDisk(range: range) else { return false }
                upgraded.append(VerifiedSparseChunk(range: range, digest: Self.digest(bytes)))
            }
            guard validateAndRestore(chunks: upgraded, expectedBytes: legacy.expectedBytes) else { return false }
            requiresRestoredCacheValidation = true
            persistSidecar()
            return true
        }
        return false
    }

    private func validateAndRestore(chunks: [VerifiedSparseChunk], expectedBytes: Int64) -> Bool {
        let furthest = chunks.map(\.range.upperBound).max() ?? 0
        guard expectedBytes > 0,
              let size = try? cacheURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              Int64(size) >= furthest else { return false }
        var restoredIndex = SparseByteRangeIndex()
        for chunk in chunks {
            guard let bytes = readBytesFromDisk(range: chunk.range),
                  Self.digest(bytes) == chunk.digest else { return false }
            restoredIndex.insert(chunk.range)
        }
        index = restoredIndex
        self.expectedBytes = expectedBytes
        verifiedChunks = chunks
        return true
    }

    private func readBytesFromDisk(range: SparseByteRange) -> Data? {
        guard range.count > 0, range.count <= Int64(Int.max),
              let handle = try? FileHandle(forReadingFrom: cacheURL) else { return nil }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: UInt64(range.lowerBound))
            let data = try handle.read(upToCount: Int(range.count))
            return data?.count == Int(range.count) ? data : nil
        } catch {
            return nil
        }
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func shortHash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).prefix(8)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func classify(_ error: Error) -> SparseDownloadFailureClass {
        if case LoaderError.invalidHTTPStatus(let status) = error {
            return SparseDownloadRetryPolicy.classify(urlErrorCode: nil, httpStatus: status)
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return SparseDownloadRetryPolicy.classify(urlErrorCode: nsError.code, httpStatus: nil)
        }
        return .terminal
    }

    static func isRetryableFailure(_ error: Error) -> Bool {
        let failure = classify(error)
        return failure == .transient || failure == .staleSource || failure == .waitingForWiFi
    }

    private func emitDiagnostic(
        stage: String,
        statusCode: Int? = nil,
        requested: SparseByteRange? = nil,
        byteCount: Int64? = nil,
        contentType: String? = nil,
        contentEncoding: String? = nil,
        bodyClass: String? = nil
    ) {
        let elapsed = ContinuousClock.now - startedAt
        diagnosticHandler(
            Diagnostic(
                stage: stage,
                elapsedMilliseconds: Int(elapsed.timeInterval * 1000),
                statusCode: statusCode,
                contentType: contentType,
                contentEncoding: contentEncoding,
                bodyClass: bodyClass,
                requestedOffset: requested?.lowerBound,
                byteCount: byteCount,
                expectedBytes: expectedBytes > 0 ? expectedBytes : nil,
                rangeSupported: rangeSupported
            )
        )
    }

    private func finish(with result: Result<Progress, Error>) {
        guard !didReportCompletion else { return }
        didReportCompletion = true
        completionHandler(result)
    }
}

private extension Duration {
    var timeInterval: TimeInterval {
        let parts = components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}
#endif
