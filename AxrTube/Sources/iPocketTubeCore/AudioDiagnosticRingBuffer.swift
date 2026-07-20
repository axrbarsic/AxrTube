import Foundation

/// A privacy-bounded audio trace. Callers pass only enum/raw-state summaries;
/// URL-like or credential-like strings are redacted defensively before storage.
public struct AudioDiagnosticEvent: Codable, Equatable, Sendable {
    public let timestamp: Date
    public let monotonicNanoseconds: UInt64?
    public let sequence: UInt64
    public let playbackSessionID: String?
    public let localItemHash: String?
    public let commandGeneration: UInt64?
    public let source: String
    public let event: String
    public let decision: String?
    public let category: String?
    public let mode: String?
    public let categoryOptions: UInt?
    public let routeOutputs: [String]
    public let interruptionType: UInt?
    public let interruptionOptions: UInt?
    public let interruptionReason: UInt?
    public let interruptionWasSuspended: Bool?
    public let playerRate: Double?
    public let timeControlStatus: Int?
    public let playerStatus: Int?
    public let itemStatus: Int?
    public let reasonForWaiting: String?
    public let errorDomain: String?
    public let errorCode: Int?
    public let recoveryGeneration: UInt?

    public init(
        timestamp: Date = .now,
        monotonicNanoseconds: UInt64? = nil,
        sequence: UInt64 = 0,
        playbackSessionID: String? = nil,
        localItemHash: String? = nil,
        commandGeneration: UInt64? = nil,
        source: String,
        event: String,
        decision: String? = nil,
        category: String? = nil,
        mode: String? = nil,
        categoryOptions: UInt? = nil,
        routeOutputs: [String] = [],
        interruptionType: UInt? = nil,
        interruptionOptions: UInt? = nil,
        interruptionReason: UInt? = nil,
        interruptionWasSuspended: Bool? = nil,
        playerRate: Double? = nil,
        timeControlStatus: Int? = nil,
        playerStatus: Int? = nil,
        itemStatus: Int? = nil,
        reasonForWaiting: String? = nil,
        errorDomain: String? = nil,
        errorCode: Int? = nil,
        recoveryGeneration: UInt? = nil
    ) {
        self.timestamp = timestamp
        self.monotonicNanoseconds = monotonicNanoseconds
        self.sequence = sequence
        self.playbackSessionID = playbackSessionID.map(Self.sanitize)
        self.localItemHash = localItemHash.map(Self.sanitize)
        self.commandGeneration = commandGeneration
        self.source = Self.sanitize(source)
        self.event = Self.sanitize(event)
        self.decision = decision.map(Self.sanitize)
        self.category = category.map(Self.sanitize)
        self.mode = mode.map(Self.sanitize)
        self.categoryOptions = categoryOptions
        self.routeOutputs = routeOutputs.map(Self.sanitize)
        self.interruptionType = interruptionType
        self.interruptionOptions = interruptionOptions
        self.interruptionReason = interruptionReason
        self.interruptionWasSuspended = interruptionWasSuspended
        self.playerRate = playerRate
        self.timeControlStatus = timeControlStatus
        self.playerStatus = playerStatus
        self.itemStatus = itemStatus
        self.reasonForWaiting = reasonForWaiting.map(Self.sanitize)
        self.errorDomain = errorDomain.map(Self.sanitize)
        self.errorCode = errorCode
        self.recoveryGeneration = recoveryGeneration
    }

    func replacingSequence(_ sequence: UInt64) -> Self {
        Self(
            timestamp: timestamp,
            monotonicNanoseconds: monotonicNanoseconds,
            sequence: sequence,
            playbackSessionID: playbackSessionID,
            localItemHash: localItemHash,
            commandGeneration: commandGeneration,
            source: source,
            event: event,
            decision: decision,
            category: category,
            mode: mode,
            categoryOptions: categoryOptions,
            routeOutputs: routeOutputs,
            interruptionType: interruptionType,
            interruptionOptions: interruptionOptions,
            interruptionReason: interruptionReason,
            interruptionWasSuspended: interruptionWasSuspended,
            playerRate: playerRate,
            timeControlStatus: timeControlStatus,
            playerStatus: playerStatus,
            itemStatus: itemStatus,
            reasonForWaiting: reasonForWaiting,
            errorDomain: errorDomain,
            errorCode: errorCode,
            recoveryGeneration: recoveryGeneration
        )
    }

    private static func sanitize(_ value: String) -> String {
        let lowered = value.lowercased()
        let forbidden = [
            "://", "?", "cookie", "token", "authorization", "signature=",
            "x-goog-", "x-amz-"
        ]
        return forbidden.contains(where: lowered.contains) ? "<redacted>" : value
    }
}

public final class AudioDiagnosticRingBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private let capacity: Int
    private var events: [AudioDiagnosticEvent] = []
    private var nextSequence: UInt64 = 1

    public init(capacity: Int = 256) {
        self.capacity = max(1, capacity)
    }

    @discardableResult
    public func append(_ event: AudioDiagnosticEvent) -> AudioDiagnosticEvent {
        lock.lock()
        defer { lock.unlock() }
        let sequenced = event.replacingSequence(nextSequence)
        nextSequence &+= 1
        events.append(sequenced)
        if events.count > capacity {
            events.removeFirst(events.count - capacity)
        }
        return sequenced
    }

    public func snapshot() -> [AudioDiagnosticEvent] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }

    public func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        events.removeAll(keepingCapacity: true)
    }
}
