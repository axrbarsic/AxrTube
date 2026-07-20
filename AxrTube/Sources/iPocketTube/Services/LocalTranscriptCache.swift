import Foundation
import iPocketTubeCore

actor LocalTranscriptCache {
    struct Record: Codable, Equatable, Sendable {
        let algorithmVersion: Int
        let videoID: String
        let localeIdentifier: String
        let engine: LocalTranscriptionEngine
        let createdAt: Date
        let cues: [CaptionCue]
    }

    static let algorithmVersion = 2

    private let directory: URL
    private let fileManager: FileManager

    init(baseDirectory: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let root = baseDirectory ?? fileManager
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.directory = root
            .appendingPathComponent("AxrTubeTranscripts", isDirectory: true)
            .appendingPathComponent("v\(Self.algorithmVersion)", isDirectory: true)
    }

    func load(videoID: String) -> LocalTranscriptResult? {
        let url = recordURL(videoID: videoID)
        guard let data = try? Data(contentsOf: url),
              let record = try? JSONDecoder().decode(Record.self, from: data),
              record.algorithmVersion == Self.algorithmVersion,
              record.videoID == videoID else { return nil }
        let cues = CaptionTranscriptPolicy.normalizedCues(record.cues)
        guard !cues.isEmpty else { return nil }
        return LocalTranscriptResult(
            cues: cues,
            localeIdentifier: record.localeIdentifier,
            wasCached: true,
            engine: record.engine
        )
    }

    func store(
        videoID: String,
        localeIdentifier: String,
        engine: LocalTranscriptionEngine,
        cues: [CaptionCue]
    ) throws {
        let normalized = CaptionTranscriptPolicy.normalizedCues(cues)
        guard !normalized.isEmpty else { return }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = recordURL(videoID: videoID)
        let staging = destination.appendingPathExtension("new")
        defer { try? fileManager.removeItem(at: staging) }
        let record = Record(
            algorithmVersion: Self.algorithmVersion,
            videoID: videoID,
            localeIdentifier: localeIdentifier,
            engine: engine,
            createdAt: Date(),
            cues: normalized
        )
        let data = try JSONEncoder().encode(record)
        try data.write(to: staging, options: .atomic)
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(
                destination,
                withItemAt: staging,
                backupItemName: nil,
                options: .usingNewMetadataOnly
            )
        } else {
            try fileManager.moveItem(at: staging, to: destination)
        }
    }

    func recordURL(videoID: String) -> URL {
        let safeID = videoID.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? videoID
        return directory.appendingPathComponent("\(safeID).json")
    }

    func stagingURL(videoID: String) -> URL {
        recordURL(videoID: videoID).appendingPathExtension("new")
    }
}
