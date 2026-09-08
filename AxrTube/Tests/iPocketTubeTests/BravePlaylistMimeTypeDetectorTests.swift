import Foundation
import Testing
@testable import iPocketTube

@Suite("Brave Playlist MIME detector port")
struct BravePlaylistMimeTypeDetectorTests {
    @Test("Detects media from URL and response MIME type")
    func metadataDetection() throws {
        let url = try #require(URL(string: "https://example.com/movie.m4v"))
        #expect(PlaylistMimeTypeDetector(url: url).fileExtension == "m4v")
        #expect(PlaylistMimeTypeDetector(mimeType: "video/quicktime").fileExtension == "mov")
    }

    @Test("Detects an ISO MP4 file signature")
    func signatureDetection() {
        let signature = Data([0, 0, 0, 24, 0x66, 0x74, 0x79, 0x70, 0x69, 0x73, 0x6F, 0x6D])
        let detector = PlaylistMimeTypeDetector(data: signature)
        #expect(detector.mimeType == "video/mp4")
        #expect(detector.fileExtension == "mp4")
    }
}
