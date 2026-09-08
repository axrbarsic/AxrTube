import Foundation
import Testing
@testable import iPocketTubeCore

@Suite("Durable offline ranges")
struct OfflineRangeJournalTests {
    private func fixture(_ body: (URL, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let piece = root.appendingPathComponent("piece")
        try Data([1, 2, 3]).write(to: piece)
        try body(root.appendingPathComponent("journal"), piece)
    }

    @Test func resumesCommittedPrefixAndDropsUncommittedTail() throws {
        try fixture { directory, piece in
            let first = try OfflineRangeJournal(directory: directory, representation: "a:18")
            try first.commit(piece: piece, contentRange: "bytes 0-2/6", etag: "\"stable\"")
            let file = try FileHandle(forWritingTo: first.dataURL)
            try file.seekToEnd()
            try file.write(contentsOf: Data([9, 9]))
            try file.close()
            let resumed = try OfflineRangeJournal(directory: directory, representation: "a:18")
            #expect(resumed.rangeHeader == "bytes=3-5")
            #expect(try Data(contentsOf: resumed.dataURL) == Data([1, 2, 3]))
            try resumed.commit(piece: piece, contentRange: "bytes 3-5/6", etag: "\"stable\"")
            #expect(resumed.isComplete)
            #expect(resumed.progress == 1)
            #expect(try Data(contentsOf: resumed.dataURL) == Data([1, 2, 3, 1, 2, 3]))
        }
    }

    @Test func rejectsChangedIdentityAndInvalidResponseWithoutLosingPrefix() throws {
        try fixture { directory, piece in
            let journal = try OfflineRangeJournal(directory: directory, representation: "a:18")
            try journal.commit(piece: piece, contentRange: "bytes 0-2/6", etag: "\"one\"")
            #expect(throws: (any Error).self) {
                try journal.commit(piece: piece, contentRange: "bytes 3-5/6", etag: "\"two\"")
            }
            #expect(throws: (any Error).self) {
                try journal.commit(piece: piece, contentRange: "bytes 0-2/6", etag: "\"one\"")
            }
            #expect(throws: (any Error).self) {
                _ = try OfflineRangeJournal(directory: directory, representation: "a:22")
            }
            #expect(journal.state.committed == 3)
            #expect(try Data(contentsOf: journal.dataURL) == Data([1, 2, 3]))
        }
    }

    @Test func missingValidatorAndCorruptManifestDoNotDestroyData() throws {
        try fixture { directory, piece in
            let journal = try OfflineRangeJournal(directory: directory, representation: "a:18")
            #expect(throws: (any Error).self) {
                try journal.commit(piece: piece, contentRange: "bytes 0-2/6", etag: nil)
            }
            try journal.commit(piece: piece, contentRange: "bytes 0-2/6", etag: "\"one\"")
            try Data("broken".utf8).write(to: directory.appendingPathComponent("journal.json"))
            #expect(throws: (any Error).self) {
                _ = try OfflineRangeJournal(directory: directory, representation: "a:18")
            }
            #expect(try Data(contentsOf: journal.dataURL) == Data([1, 2, 3]))
        }
    }

    @Test func retryBudgetIsBoundedAndDoesNotRetryPermanentErrors() {
        #expect(PlaylistDownloadPolicy.retryDelay(errorCode: NSURLErrorTimedOut, httpStatus: nil, attempt: 0) == 5)
        #expect(PlaylistDownloadPolicy.retryDelay(errorCode: 0, httpStatus: 503, attempt: 4) == 80)
        #expect(PlaylistDownloadPolicy.retryDelay(errorCode: 0, httpStatus: 429, attempt: 5) == nil)
        #expect(PlaylistDownloadPolicy.retryDelay(errorCode: 0, httpStatus: 403, attempt: 0) == nil)
        #expect(PlaylistDownloadPolicy.retryDelay(errorCode: NSURLErrorCancelled, httpStatus: nil, attempt: 0) == nil)
    }
}
