import Foundation
import OSLog
import Testing
@testable import iPocketTubeCore

// MARK: - Playlist mock data

private nonisolated(unsafe) let mockLibraryResponse: [String: Any] = [
    "contents": [
        "singleColumnBrowseResultsRenderer": [
            "tabs": [
                [
                    "tabRenderer": [
                        "content": [
                            "sectionListRenderer": [
                                "contents": [
                                    [
                                        "itemSectionRenderer": [
                                            "contents": [
                                                [
                                                    "gridRenderer": [
                                                        "items": [
                                                            [
                                                                "gridPlaylistRenderer": [
                                                                    "playlistId": "PLdummy0001",
                                                                    "title": ["simpleText": "Favourites"],
                                                                    "videoCountText": ["runs": [["text": "12 videos"]]],
                                                                    "thumbnail": [
                                                                        "thumbnails": [
                                                                            ["url": "https://i.ytimg.com/vi/abc/hqdefault.jpg"]
                                                                        ]
                                                                    ]
                                                                ]
                                                            ],
                                                            [
                                                                "gridPlaylistRenderer": [
                                                                    "playlistId": "PLdummy0002",
                                                                    "title": ["simpleText": "Watch Later"],
                                                                    "videoCountText": ["runs": [["text": "5 videos"]]],
                                                                    "thumbnail": [
                                                                        "thumbnails": [
                                                                            ["url": "https://i.ytimg.com/vi/xyz/hqdefault.jpg"]
                                                                        ]
                                                                    ]
                                                                ]
                                                            ],
                                                            [
                                                                "gridPlaylistRenderer": [
                                                                    "playlistId": "PLdummy0003",
                                                                    "title": ["simpleText": "Music Mix"],
                                                                    "videoCount": "27",
                                                                    "thumbnail": [
                                                                        "thumbnails": [
                                                                            ["url": "https://i.ytimg.com/vi/zzz/hqdefault.jpg"]
                                                                        ]
                                                                    ]
                                                                ]
                                                            ]
                                                        ]
                                                    ]
                                                ]
                                            ]
                                        ]
                                    ]
                                ]
                            ]
                        ]
                    ]
                ]
            ]
        ]
    ]
]

// MARK: - PlaylistsUITests

@Suite("Playlists UI")
struct PlaylistsUITests {

    // MARK: - Renders correct playlist rows

    @Test("Parses all three gridPlaylistRenderer items into PlaylistInfo rows")
    func parsesAllPlaylistRows() async throws {
        let api = InnerTubeAPI()
        let playlists = try await api.parsePlaylistsForTesting(mockLibraryResponse)

        #expect(playlists.count == 3, "Library grid should produce one row per playlist")
    }

    @Test("Each playlist row carries its id, title and thumbnail URL")
    func playlistRowContent() async throws {
        let api = InnerTubeAPI()
        let playlists = try await api.parsePlaylistsForTesting(mockLibraryResponse)

        let favourites = try #require(playlists.first(where: { $0.id == "PLdummy0001" }))
        #expect(favourites.title == "Favourites")
        #expect(favourites.thumbnailURL?.absoluteString.contains("ytimg.com") == true)

        let watchLater = try #require(playlists.first(where: { $0.id == "PLdummy0002" }))
        #expect(watchLater.title == "Watch Later")

        let musicMix = try #require(playlists.first(where: { $0.id == "PLdummy0003" }))
        #expect(musicMix.title == "Music Mix")
    }

    @Test("videoCountText runs format ('12 videos') is parsed to an Int")
    func videoCountParsedFromRuns() async throws {
        let api = InnerTubeAPI()
        let playlists = try await api.parsePlaylistsForTesting(mockLibraryResponse)
        let favourites = try #require(playlists.first(where: { $0.id == "PLdummy0001" }))
        #expect(favourites.videoCount == 12)
    }

    @Test("videoCount plain string ('27') is parsed to an Int")
    func videoCountParsedFromPlainString() async throws {
        let api = InnerTubeAPI()
        let playlists = try await api.parsePlaylistsForTesting(mockLibraryResponse)
        let musicMix = try #require(playlists.first(where: { $0.id == "PLdummy0003" }))
        #expect(musicMix.videoCount == 27)
    }

    @Test("Empty response produces an empty playlists array")
    func emptyResponseProducesEmptyArray() async throws {
        let api = InnerTubeAPI()
        let playlists = try await api.parsePlaylistsForTesting([:])
        #expect(playlists.isEmpty)
    }

    // MARK: - Reads the OS log written by parsePlaylists

    @Test("parsePlaylists emits a log entry containing the playlist count")
    func logEntryContainsPlaylistCount() async throws {
        // Snapshot the log position before the call so we only read new entries.
        let before = Date()

        let api = InnerTubeAPI()
        let playlists = try await api.parsePlaylistsForTesting(mockLibraryResponse)

        // Give the logging subsystem a moment to flush the entry.
        try await Task.sleep(for: .milliseconds(200))

        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let position = store.position(date: before)
        let entries = try store.getEntries(at: position)
            .compactMap { $0 as? OSLogEntryLog }
            .filter { $0.subsystem == appSubsystem && $0.category == "InnerTube" }

        let countMessage = "\(playlists.count) playlists"
        let matched = entries.contains { $0.composedMessage.contains(countMessage) }
        #expect(matched, "Expected a log entry containing '\(countMessage)'")
    }
}
