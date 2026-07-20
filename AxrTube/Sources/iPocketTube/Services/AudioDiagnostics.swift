#if canImport(UIKit)
import AVFoundation
import CryptoKit
import Foundation
import iPocketTubeCore

/// Process-wide, privacy-safe audio diagnostics persisted for the next device
/// investigation. The file can be pulled from the app data container without
/// reproducing a second time. It intentionally stores no media URL or metadata.
final class AudioDiagnostics: @unchecked Sendable {
    static let shared = AudioDiagnostics()
    // Legacy path keeps already persisted diagnostics available after install-over.
    static let relativeExportPath = "Library/Application Support/SmartTube/Diagnostics/playback-lifecycle.json"

    private let ring = AudioDiagnosticRingBuffer(capacity: 512)
    private let persistenceLock = NSLock()
    private let fileURL: URL?
    private let playbackSessionID = UUID().uuidString

    private init() {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first
        fileURL = support?
            .appendingPathComponent("SmartTube/Diagnostics", isDirectory: true)
            .appendingPathComponent("playback-lifecycle.json", isDirectory: false)

        guard let fileURL,
              let data = try? Data(contentsOf: fileURL),
              let previous = try? JSONDecoder.audioDiagnostics.decode(
                [AudioDiagnosticEvent].self,
                from: data
              ) else { return }
        for event in previous.suffix(512) {
            ring.append(event)
        }
    }

    var exportURL: URL? { fileURL }

    func record(
        source: String = "avplayer",
        event: String,
        decision: String? = nil,
        player: AVPlayer? = nil,
        interruptionType: UInt? = nil,
        interruptionOptions: UInt? = nil,
        interruptionReason: UInt? = nil,
        interruptionWasSuspended: Bool? = nil,
        recoveryGeneration: UInt? = nil,
        itemID: String? = nil,
        commandGeneration: UInt64? = nil,
        error: Error? = nil
    ) {
        let session = AVAudioSession.sharedInstance()
        let playerError = player?.error as NSError?
        let itemError = player?.currentItem?.error as NSError?
        let effectiveError = (error as NSError?) ?? playerError ?? itemError
        ring.append(AudioDiagnosticEvent(
            monotonicNanoseconds: DispatchTime.now().uptimeNanoseconds,
            playbackSessionID: playbackSessionID,
            localItemHash: itemID.map(Self.hashItemID),
            commandGeneration: commandGeneration,
            source: source,
            event: event,
            decision: decision,
            category: session.category.rawValue,
            mode: session.mode.rawValue,
            categoryOptions: session.categoryOptions.rawValue,
            routeOutputs: session.currentRoute.outputs.map { $0.portType.rawValue },
            interruptionType: interruptionType,
            interruptionOptions: interruptionOptions,
            interruptionReason: interruptionReason,
            interruptionWasSuspended: interruptionWasSuspended,
            playerRate: player.map { Double($0.rate) },
            timeControlStatus: player?.timeControlStatus.rawValue,
            playerStatus: player?.status.rawValue,
            itemStatus: player?.currentItem?.status.rawValue,
            reasonForWaiting: player?.reasonForWaitingToPlay?.rawValue,
            errorDomain: effectiveError?.domain,
            errorCode: effectiveError?.code,
            recoveryGeneration: recoveryGeneration
        ))
        persist()
    }

    func snapshot() -> [AudioDiagnosticEvent] {
        ring.snapshot()
    }

    private static func hashItemID(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    private func persist() {
        guard let fileURL else { return }
        persistenceLock.lock()
        defer { persistenceLock.unlock() }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder.audioDiagnostics.encode(ring.snapshot())
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Diagnostics must never affect playback. The normal OSLog path remains.
        }
    }
}

private extension JSONEncoder {
    static var audioDiagnostics: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var audioDiagnostics: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
#endif
