import Foundation

package actor RussianTranscriptCache {
    package struct Record: Codable, Equatable, Sendable {
        package let schemaVersion: Int
        package let videoID: String
        package let sourceTrackID: String
        package let sourceHash: String
        package let sourceLocale: String
        package let targetLocale: String
        package let completed: Bool
        package let resumeCount: Int
        package let translationsByIndex: [Int: String]
    }

    private let directory: URL
    private let fileManager: FileManager

    package init(baseDirectory: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let root = baseDirectory ?? fileManager
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        directory = root
            .appendingPathComponent("AxrTubeRussianTranscripts", isDirectory: true)
            .appendingPathComponent(
                "v\(RussianTranscriptPolicy.cacheSchemaVersion)",
                isDirectory: true
            )
    }

    package func load(request: RussianTranscriptRequest) -> Record? {
        let url = recordURL(request: request)
        guard let data = try? Data(contentsOf: url),
              let record = try? JSONDecoder().decode(Record.self, from: data),
              record.schemaVersion == RussianTranscriptPolicy.cacheSchemaVersion,
              record.videoID == request.videoID,
              record.sourceTrackID == request.sourceTrackID,
              record.sourceHash == request.sourceHash,
              record.sourceLocale == "en",
              record.targetLocale == "ru" else { return nil }
        return record
    }

    package func store(
        request: RussianTranscriptRequest,
        translationsByIndex: [Int: String],
        completed: Bool,
        resumeCount: Int
    ) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = recordURL(request: request)
        let record = Record(
            schemaVersion: RussianTranscriptPolicy.cacheSchemaVersion,
            videoID: request.videoID,
            sourceTrackID: request.sourceTrackID,
            sourceHash: request.sourceHash,
            sourceLocale: "en",
            targetLocale: "ru",
            completed: completed,
            resumeCount: resumeCount,
            translationsByIndex: translationsByIndex
        )
        try JSONEncoder().encode(record).write(to: destination, options: .atomic)
    }

    private func recordURL(request: RussianTranscriptRequest) -> URL {
        let safeVideoID = request.videoID
            .addingPercentEncoding(withAllowedCharacters: .alphanumerics)
            ?? "video"
        let safeTrackID = request.sourceTrackID
            .addingPercentEncoding(withAllowedCharacters: .alphanumerics)
            ?? "track"
        return directory.appendingPathComponent(
            "\(safeVideoID)-\(safeTrackID)-\(request.sourceHash)-en-ru.json"
        )
    }
}
