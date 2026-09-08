import Foundation

/// Durable contiguous pieces. Only bytes recorded in the atomic manifest count
/// as committed; an interrupted append is truncated on the next open.
public final class OfflineRangeJournal {
    public struct State: Codable, Equatable, Sendable {
        public var representation: String
        public var committed: Int64 = 0
        public var total: Int64?
        public var validator: String?
    }
    public enum Failure: Error { case invalidRange, changedResource, missingValidator, incomplete }
    public static let pieceSize: Int64 = 8 * 1024 * 1024
    public let directory: URL
    public let dataURL: URL
    public private(set) var state: State
    private var manifestURL: URL { directory.appendingPathComponent("journal.json") }

    public init(directory: URL, representation: String) throws {
        self.directory = directory
        dataURL = directory.appendingPathComponent("media.part")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let manifest = directory.appendingPathComponent("journal.json")
        if FileManager.default.fileExists(atPath: manifest.path) {
            let saved = try JSONDecoder().decode(State.self, from: Data(contentsOf: manifest))
            guard saved.representation == representation else { throw Failure.changedResource }
            guard saved.committed >= 0, saved.total.map({ $0 > 0 && saved.committed <= $0 }) ?? (saved.committed == 0),
                  saved.committed == 0 || saved.validator != nil else { throw Failure.incomplete }
            state = saved
        } else { state = State(representation: representation) }
        if !FileManager.default.fileExists(atPath: dataURL.path) {
            guard state.committed == 0 else { throw Failure.incomplete }
            FileManager.default.createFile(atPath: dataURL.path, contents: nil)
        }
        let file = try FileHandle(forUpdating: dataURL)
        defer { try? file.close() }
        let size = try file.seekToEnd()
        guard state.committed >= 0, size >= UInt64(state.committed) else { throw Failure.incomplete }
        try file.truncate(atOffset: UInt64(state.committed))
    }

    public var rangeHeader: String {
        let remaining = (state.total ?? Int64.max) - state.committed
        let end = state.committed + min(Self.pieceSize, remaining) - 1
        return "bytes=\(state.committed)-\(max(state.committed, end))"
    }
    public var isComplete: Bool { state.total.map { $0 > 0 && $0 == state.committed } ?? false }
    public var progress: Double { state.total.map { Double(state.committed) / Double(max(1, $0)) } ?? 0 }

    public func commit(piece: URL, contentRange: String, etag: String?) throws {
        guard let range = Self.parse(contentRange), range.start == state.committed,
              range.end >= range.start, range.end < range.total else { throw Failure.invalidRange }
        let size = try piece.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard Int64(size) == range.end - range.start + 1 else { throw Failure.invalidRange }
        let validator = etag.flatMap { $0.hasPrefix("W/") || $0.isEmpty ? nil : $0 }
        // Never splice a refreshed URL without a strong identity validator.
        guard let validator else { throw Failure.missingValidator }
        if let old = state.validator, old != validator { throw Failure.changedResource }
        if let total = state.total, total != range.total { throw Failure.changedResource }
        let input = try FileHandle(forReadingFrom: piece)
        let output = try FileHandle(forUpdating: dataURL)
        defer { try? input.close(); try? output.close() }
        try output.seek(toOffset: UInt64(state.committed))
        while let block = try input.read(upToCount: 64 * 1024), !block.isEmpty {
            try output.write(contentsOf: block)
        }
        try output.synchronize()
        var next = state
        next.committed = range.end + 1
        next.total = range.total
        next.validator = validator
        try JSONEncoder().encode(next).write(to: manifestURL, options: .atomic)
        state = next
    }

    public static func parse(_ value: String) -> (start: Int64, end: Int64, total: Int64)? {
        guard value.hasPrefix("bytes ") else { return nil }
        let pieces = value.dropFirst(6).split(separator: "/")
        guard pieces.count == 2, let total = Int64(pieces[1]), total > 0 else { return nil }
        let bounds = pieces[0].split(separator: "-")
        guard bounds.count == 2, let start = Int64(bounds[0]), let end = Int64(bounds[1]),
              start >= 0, end >= start, end < total else { return nil }
        return (start, end, total)
    }
}
