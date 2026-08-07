import Foundation

/// Monotonic command identity. Comparing only a video ID is insufficient for
/// A -> B -> A because a late callback from the first A otherwise looks current.
public struct PlaybackCommandGate: Sendable, Equatable {
    public private(set) var generation: UInt64 = 0

    public init() {}

    @discardableResult
    public mutating func advance() -> UInt64 {
        generation &+= 1
        return generation
    }

    public func isCurrent(_ candidate: UInt64) -> Bool {
        candidate == generation
    }
}

/// Rejects completions from a cancelled or superseded byte-range request. A
/// range can be reissued immediately for player priority, so range identity
/// alone is insufficient to decide whether an async URLSession response is
/// still allowed to mutate the durable cache.
public struct SparseRangeRequestGenerationGate: Sendable, Equatable {
    private var nextGeneration: UInt64 = 0
    private var generations: [SparseByteRange: UInt64] = [:]

    public init() {}

    public mutating func issue(for range: SparseByteRange) -> UInt64 {
        nextGeneration &+= 1
        generations[range] = nextGeneration
        return nextGeneration
    }

    public func accepts(_ generation: UInt64, for range: SparseByteRange) -> Bool {
        generations[range] == generation
    }

    @discardableResult
    public mutating func consume(_ generation: UInt64, for range: SparseByteRange) -> Bool {
        guard accepts(generation, for: range) else { return false }
        generations[range] = nil
        return true
    }

    public mutating func invalidate(_ range: SparseByteRange) {
        generations[range] = nil
    }

    public mutating func invalidateAll() {
        generations.removeAll()
    }
}

public enum PlaybackSceneState: String, Codable, Sendable {
    case active
    case inactive
    case background
}

public enum PlaybackLifecyclePolicy {
    public static func shouldRunStallRecovery(
        scene: PlaybackSceneState,
        hasTrueAudioInterruption: Bool,
        isReplacingItem: Bool
    ) -> Bool {
        scene == .active && !hasTrueAudioInterruption && !isReplacingItem
    }
}

public enum AudioFirstColdStartDecision: Sendable, Equatable {
    case playCompletedLocal
    case resumePartialCache
    case resolveNetwork
}

public enum AudioFirstColdStartPolicy {
    public static func decide(
        manifestReady: Bool,
        hasReadableCompletedLocalFile: Bool,
        hasPartialRanges: Bool
    ) -> AudioFirstColdStartDecision {
        guard manifestReady else { return .resolveNetwork }
        if hasReadableCompletedLocalFile { return .playCompletedLocal }
        if hasPartialRanges { return .resumePartialCache }
        return .resolveNetwork
    }
}

/// Half-open byte interval used by the instant-audio sparse cache.
public struct SparseByteRange: Codable, Hashable, Sendable, Comparable {
    public let lowerBound: Int64
    public let upperBound: Int64

    public init(_ lowerBound: Int64, _ upperBound: Int64) {
        self.lowerBound = max(0, lowerBound)
        self.upperBound = max(self.lowerBound, upperBound)
    }

    public var count: Int64 { upperBound - lowerBound }
    public var isEmpty: Bool { count == 0 }

    public func intersects(_ other: Self) -> Bool {
        lowerBound < other.upperBound && other.lowerBound < upperBound
    }

    public func contains(_ other: Self) -> Bool {
        lowerBound <= other.lowerBound && upperBound >= other.upperBound
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.lowerBound == rhs.lowerBound
            ? lhs.upperBound < rhs.upperBound
            : lhs.lowerBound < rhs.lowerBound
    }
}

/// Pure interval index. Disk IO and networking live in the iOS loader, while
/// this type makes range merging, cache hits and stale-URL preservation testable.
public struct SparseByteRangeIndex: Codable, Sendable, Equatable {
    public private(set) var ranges: [SparseByteRange] = []

    public init(ranges: [SparseByteRange] = []) {
        for range in ranges { insert(range) }
    }

    public var cachedByteCount: Int64 { ranges.reduce(0) { $0 + $1.count } }

    public mutating func insert(_ inserted: SparseByteRange) {
        guard !inserted.isEmpty else { return }
        var merged = inserted
        var output: [SparseByteRange] = []
        var didInsert = false

        for current in ranges {
            if current.upperBound < merged.lowerBound {
                output.append(current)
            } else if merged.upperBound < current.lowerBound {
                if !didInsert { output.append(merged); didInsert = true }
                output.append(current)
            } else {
                merged = SparseByteRange(
                    min(merged.lowerBound, current.lowerBound),
                    max(merged.upperBound, current.upperBound)
                )
            }
        }
        if !didInsert { output.append(merged) }
        ranges = output
    }

    public func contains(_ range: SparseByteRange) -> Bool {
        ranges.contains { $0.contains(range) }
    }

    public func contiguousCachedRange(startingAt offset: Int64) -> SparseByteRange? {
        ranges.first { $0.lowerBound <= offset && offset < $0.upperBound }
    }

    public func missingRanges(in requested: SparseByteRange) -> [SparseByteRange] {
        guard !requested.isEmpty else { return [] }
        var cursor = requested.lowerBound
        var missing: [SparseByteRange] = []
        for cached in ranges where cached.upperBound > requested.lowerBound && cached.lowerBound < requested.upperBound {
            if cached.lowerBound > cursor {
                missing.append(SparseByteRange(cursor, min(cached.lowerBound, requested.upperBound)))
            }
            cursor = max(cursor, cached.upperBound)
            if cursor >= requested.upperBound { break }
        }
        if cursor < requested.upperBound { missing.append(SparseByteRange(cursor, requested.upperBound)) }
        return missing.filter { !$0.isEmpty }
    }
}

/// Stable, URL-free description of the media representation backing a sparse
/// cache. Signed CDN URLs are deliberately excluded because they expire.
public struct SparseSourceFingerprint: Codable, Sendable, Equatable {
    public let videoID: String
    public let profile: String
    public let mimeType: String
    public let contentLength: Int64?
    public let entityTag: String?
    public let lastModified: String?

    public init(
        videoID: String,
        profile: String,
        mimeType: String,
        contentLength: Int64? = nil,
        entityTag: String? = nil,
        lastModified: String? = nil
    ) {
        self.videoID = videoID
        self.profile = profile
        self.mimeType = mimeType
        self.contentLength = contentLength
        self.entityTag = entityTag
        self.lastModified = lastModified
    }

    /// A refreshed signed URL may continue the existing cache only when the
    /// representation identity is unchanged. Validators strengthen the match
    /// when the server supplies them but their absence does not erase valid data.
    public func isCompatible(with refreshed: Self) -> Bool {
        guard videoID == refreshed.videoID,
              profile == refreshed.profile,
              mimeType == refreshed.mimeType else { return false }
        if let lhs = contentLength, let rhs = refreshed.contentLength, lhs != rhs { return false }
        if let lhs = entityTag, let rhs = refreshed.entityTag, lhs != rhs { return false }
        if let lhs = lastModified, let rhs = refreshed.lastModified, lhs != rhs { return false }
        return true
    }
}

public struct VerifiedSparseChunk: Codable, Sendable, Equatable {
    public let range: SparseByteRange
    public let digest: String

    public init(range: SparseByteRange, digest: String) {
        self.range = range
        self.digest = digest
    }
}

public enum SparseRestoredCacheValidator {
    /// A restored entity is reusable only after a strict partial response proves
    /// both representation identity and exact probe-byte continuity. A 200 to
    /// If-Range is deliberately rejected so old and new entities are never mixed.
    public static func accepts(
        cachedProbe: Data?,
        responseProbe: Data,
        serverReturnedWholeBody: Bool,
        cachedFingerprint: SparseSourceFingerprint,
        responseFingerprint: SparseSourceFingerprint
    ) -> Bool {
        !serverReturnedWholeBody
            && cachedProbe == responseProbe
            && cachedFingerprint.isCompatible(with: responseFingerprint)
    }
}

public enum SparseRestoredCacheResponseDecision: Sendable, Equatable {
    case resumeVerifiedCache
    case resetChangedRepresentation
    case failPreservingVerifiedCache
}

/// Only proof of a changed entity may invalidate verified bytes. A malformed
/// or mismatched Content-Range is a failed transfer, not evidence that the
/// persisted representation changed.
public enum SparseRestoredCacheResponsePolicy {
    public static func decide(
        hasValidPlacement: Bool,
        validatorAccepted: Bool
    ) -> SparseRestoredCacheResponseDecision {
        guard hasValidPlacement else { return .failPreservingVerifiedCache }
        return validatorAccepted ? .resumeVerifiedCache : .resetChangedRepresentation
    }
}

/// Versioned, atomically persisted sidecar for crash-safe range continuation.
public struct SparseCacheManifest: Codable, Sendable, Equatable {
    public static let currentVersion = 2

    public var version: Int
    public var fingerprint: SparseSourceFingerprint
    public var index: SparseByteRangeIndex
    public var verifiedChunks: [VerifiedSparseChunk]
    public var rangeSupported: Bool?
    public var retryCount: Int
    public var updatedAt: Date

    public init(
        version: Int = currentVersion,
        fingerprint: SparseSourceFingerprint,
        index: SparseByteRangeIndex = .init(),
        verifiedChunks: [VerifiedSparseChunk] = [],
        rangeSupported: Bool? = nil,
        retryCount: Int = 0,
        updatedAt: Date = .now
    ) {
        self.version = version
        self.fingerprint = fingerprint
        self.index = index
        self.verifiedChunks = verifiedChunks
        self.rangeSupported = rangeSupported
        self.retryCount = retryCount
        self.updatedAt = updatedAt
    }
}

public enum SparseDownloadFailureClass: Sendable, Equatable {
    case transient
    case staleSource
    case waitingForWiFi
    case storageFull
    case corruptRange
    case unsupported
    case terminal
}

public enum SparseDownloadRetryPolicy {
    public static func classify(urlErrorCode: Int?, httpStatus: Int?) -> SparseDownloadFailureClass {
        if let status = httpStatus {
            if status == 401 || status == 403 || status == 410 { return .staleSource }
            if status == 408 || status == 429 || (500...599).contains(status) { return .transient }
            if status == 416 { return .corruptRange }
            if status == 415 { return .unsupported }
            return .terminal
        }
        guard let code = urlErrorCode else { return .terminal }
        let transient = [
            NSURLErrorTimedOut,
            NSURLErrorCannotFindHost,
            NSURLErrorCannotConnectToHost,
            NSURLErrorNetworkConnectionLost,
            NSURLErrorDNSLookupFailed,
            NSURLErrorNotConnectedToInternet,
            NSURLErrorInternationalRoamingOff,
            NSURLErrorDataNotAllowed,
        ]
        return transient.contains(code) ? .transient : .terminal
    }

    public static func delayMilliseconds(attempt: Int, seed: Int64) -> Int {
        let boundedAttempt = min(max(0, attempt), 5)
        let base = 400 * (1 << boundedAttempt)
        let jitter = Int(abs(seed % 173))
        return min(12_000, base + jitter)
    }

    public static func shouldRetry(
        failure: SparseDownloadFailureClass,
        attempt: Int,
        maximumAttempts: Int = 5
    ) -> Bool {
        (failure == .transient || failure == .staleSource)
            && attempt < max(0, maximumAttempts)
    }
}

/// Privacy-safe validation for media responses used by the sparse loader.
/// It deliberately reasons only about header classes and byte counts. Response
/// bodies, URLs and signed query values never enter diagnostics.
public enum SparseHTTPMediaResponsePolicy {
    public static func normalizedContentType(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value
            .split(separator: ";", maxSplits: 1)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return normalized?.isEmpty == false ? normalized : nil
    }

    public static func acceptsContentType(expected: String, response: String?) -> Bool {
        guard let actual = normalizedContentType(response) else { return true }
        let expectedBase = normalizedContentType(expected)
        return actual == expectedBase
            || actual == "application/octet-stream"
            || actual == "binary/octet-stream"
    }

    public static func acceptsContentEncoding(_ value: String?) -> Bool {
        guard let value else { return true }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty || normalized == "identity"
    }

    public static func bodyClass(contentType: String?, byteCount: Int) -> String {
        guard byteCount > 0 else { return "empty" }
        switch normalizedContentType(contentType) {
        case "application/json": return "json"
        case "text/html": return "html"
        case let value? where value.hasPrefix("text/"): return "text"
        case let value? where value.hasPrefix("audio/") || value.hasPrefix("video/"):
            return "media"
        case "application/octet-stream", "binary/octet-stream": return "binary-media"
        default: return "binary-unknown"
        }
    }

    public static func encodingClass(_ value: String?) -> String {
        guard let value else { return "none" }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.isEmpty { return "none" }
        if normalized == "identity" || normalized == "gzip" || normalized == "br" || normalized == "deflate" {
            return normalized
        }
        return "other"
    }
}

/// A terminal failure without a proven player source must detach the global
/// now-playing identity. Keeping it selected makes a failed download appear to
/// be playing and lets stale remote controls target an item that cannot open.
public enum AudioFirstTerminalPresentationPolicy {
    public static func shouldDetachNowPlaying(hasPlayableSource: Bool) -> Bool {
        !hasPlayableSource
    }
}

/// Tracks reservations separately from the cached index so overlapping AVPlayer
/// requests are coalesced while cancellation immediately makes a range eligible
/// for a fresh request.
public struct SparseByteRangeRequestSet: Sendable, Equatable {
    public private(set) var ranges: Set<SparseByteRange> = []

    public init() {}

    public var count: Int { ranges.count }

    @discardableResult
    public mutating func reserve(
        _ range: SparseByteRange,
        cached index: SparseByteRangeIndex
    ) -> Bool {
        guard !range.isEmpty,
              !index.contains(range),
              !ranges.contains(where: { $0.intersects(range) }) else { return false }
        ranges.insert(range)
        return true
    }

    public mutating func remove(_ range: SparseByteRange) {
        ranges.remove(range)
    }

    public mutating func removeAll() {
        ranges.removeAll()
    }
}

/// Network tuning for the shared sparse playback/download source. Small,
/// durable ranges are intentional: on a weak connection a cancelled request
/// loses at most one bounded chunk, while AVPlayer's current read stays ahead
/// of best-effort offline completion.
public enum SparseTransferTuning {
    public static let playerChunkBytes: Int64 = 128 * 1024
    public static let backgroundChunkBytes: Int64 = 128 * 1024
    public static let mp4TailPrefetchBytes: Int64 = 128 * 1024
    public static let backgroundFallbackDelayMilliseconds = 8_000
    public static let requestTimeoutSeconds: TimeInterval = 30
    public static let resourceTimeoutSeconds: TimeInterval = 300

    public static func shouldStartBackgroundFill(
        timelineHasAdvanced: Bool,
        elapsedMilliseconds: Int
    ) -> Bool {
        timelineHasAdvanced || elapsedMilliseconds >= backgroundFallbackDelayMilliseconds
    }
}

/// AVPlayer's default HTTP waiting policy tries to predict whether playback can
/// reach the end without stalling. On a link slower than the media bitrate that
/// can postpone first audio until the whole file is cached. Progressive files
/// instead start as soon as AVFoundation has playable bytes, then return to the
/// system's conservative stall recovery after the timeline actually advances.
public enum ProgressivePlaybackWaitPolicy {
    public static func automaticallyWaitsToMinimizeStalling(
        timelineHasAdvanced: Bool
    ) -> Bool {
        timelineHasAdvanced
    }
}

/// A tiny event model used both by diagnostics and regression tests to prove
/// that playback became observable before download/export finalization.
public struct InstantAudioMilestones: Sendable, Equatable {
    public private(set) var didAdvanceTimeline = false
    public private(set) var didCompleteDownload = false
    public private(set) var didBeginExport = false

    public init() {}

    public var timelineAdvancedBeforeDownloadCompleted: Bool {
        didAdvanceTimeline && !didCompleteDownload
    }

    public mutating func timelineAdvanced() {
        didAdvanceTimeline = true
    }

    public mutating func downloadCompleted() {
        didCompleteDownload = true
    }

    public mutating func exportBegan() {
        didBeginExport = true
    }
}

public struct HTTPByteRangePlacement: Sendable, Equatable {
    public let storedRange: SparseByteRange
    public let totalLength: Int64
    public let supportsByteRanges: Bool
    public let serverReturnedWholeBody: Bool
}

public enum HTTPByteRangeInterpreter {
    /// Converts a 206/200 response into a safe sparse-file placement without
    /// carrying its URL, headers or query values into diagnostics.
    public static func placement(
        statusCode: Int,
        requested: SparseByteRange,
        contentRange: String?,
        contentLength: Int64?,
        bodyCount: Int
    ) -> HTTPByteRangePlacement? {
        guard bodyCount > 0 else { return nil }
        let bytes = Int64(bodyCount)
        if statusCode == 206,
           let parsed = parseContentRange(contentRange),
           parsed.lowerBound == requested.lowerBound,
           parsed.upperBound >= parsed.lowerBound,
           parsed.upperBound < requested.upperBound,
           parsed.upperBound < parsed.total,
           bytes == parsed.upperBound - parsed.lowerBound + 1,
           contentLength == nil || contentLength == bytes {
            return HTTPByteRangePlacement(
                storedRange: SparseByteRange(parsed.lowerBound, parsed.upperBound + 1),
                totalLength: parsed.total,
                supportsByteRanges: true,
                serverReturnedWholeBody: false
            )
        }
        if statusCode == 200 {
            guard contentLength == nil || contentLength == bytes else { return nil }
            let total = bytes
            return HTTPByteRangePlacement(
                storedRange: SparseByteRange(0, bytes),
                totalLength: total,
                supportsByteRanges: false,
                serverReturnedWholeBody: true
            )
        }
        return nil
    }

    private static func parseContentRange(_ value: String?) -> (lowerBound: Int64, upperBound: Int64, total: Int64)? {
        guard let value else { return nil }
        let parts = value.split(separator: " ", maxSplits: 1)
        guard parts.count == 2, parts[0].lowercased() == "bytes" else { return nil }
        let rangeAndTotal = parts[1].split(separator: "/", maxSplits: 1)
        let bounds = rangeAndTotal.first?.split(separator: "-", maxSplits: 1)
        guard rangeAndTotal.count == 2,
              let lowerText = bounds?.first,
              let upperText = bounds?.last,
              let lower = Int64(lowerText),
              let upper = Int64(upperText),
              let total = Int64(rangeAndTotal[1]),
              upper >= lower,
              total > upper else { return nil }
        return (lower, upper, total)
    }
}
