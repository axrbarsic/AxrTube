import Foundation
import Testing
@testable import iPocketTubeCore

// MARK: - VideoPublishAgeParserTests
//
// Relative renderer labels are presentation metadata only. Exact publication
// dates come from player microformat and are the sole sorting source.
//
// All assertions are pure value transforms — no SwiftUI, no network.

// MARK: - Helpers

/// Wraps a videoRenderer in the minimal sectionListRenderer structure for parseVideoGroupForTesting.
private func makeVideoRendererAgeResponse(_ renderer: [String: Any]) -> [String: Any] {
    [
        "contents": [
            "sectionListRenderer": [
                "contents": [
                    [
                        "itemSectionRenderer": [
                            "contents": [["videoRenderer": renderer]]
                        ]
                    ]
                ]
            ]
        ]
    ]
}

/// Wraps a lockupViewModel in the minimal structure that the walker handles at the dict level.
private func makeLockupViewModelAgeResponse(_ lockup: [String: Any]) -> [String: Any] {
    [
        "contents": [
            "sectionListRenderer": [
                "contents": [
                    [
                        "itemSectionRenderer": [
                            "contents": [["lockupViewModel": lockup]]
                        ]
                    ]
                ]
            ]
        ]
    ]
}

// MARK: - parseVideoRenderer publication label

@Suite("Task #97 — parseVideoRenderer publishedAt extraction")
struct VideoRendererPublishAgeTests {

    // A minimal valid videoRenderer dict with a publishedTimeText.simpleText field.
    private func makeRenderer(publishedTimeText: Any?) -> [String: Any] {
        var r: [String: Any] = [
            "videoId": "testvidid",
            "title": ["simpleText": "Test Video"],
            "ownerText": ["runs": [["text": "Test Channel",
                                    "navigationEndpoint": ["browseEndpoint": ["browseId": "UCtest"]]]]],
            "thumbnail": ["thumbnails": [["url": "https://i.ytimg.com/vi/testvidid/hqdefault.jpg"]]],
        ]
        if let pubText = publishedTimeText {
            r["publishedTimeText"] = pubText
        }
        return r
    }

    @Test("Relative simpleText is preserved but never promoted to exact publishedAt")
    func videoRenderer_simpleText_populatesPublishedAt() async throws {
        let response = makeVideoRendererAgeResponse(makeRenderer(
            publishedTimeText: ["simpleText": "2 years ago"]
        ))
        let api = InnerTubeAPI()
        let group = try await api.parseVideoGroupForTesting(response, title: nil)
        let video = try #require(group.videos.first, "Expected at least one video from response")
        #expect(video.publishedAt == nil)
        #expect(video.publishedTimeText == "2 years ago")
    }

    @Test("Relative runs text is preserved but exact date stays nil")
    func videoRenderer_runsText_populatesPublishedAt() async throws {
        let response = makeVideoRendererAgeResponse(makeRenderer(
            publishedTimeText: ["runs": [["text": "3 months ago"]]]
        ))
        let api = InnerTubeAPI()
        let group = try await api.parseVideoGroupForTesting(response, title: nil)
        let video = try #require(group.videos.first, "Expected at least one video from response")
        #expect(video.publishedAt == nil)
        #expect(video.publishedTimeText == "3 months ago")
    }

    @Test("Current Home renderer dateText fallback is preserved")
    func videoRenderer_dateTextFallback() async throws {
        var renderer = makeRenderer(publishedTimeText: nil)
        renderer["dateText"] = ["simpleText": "5 days ago"]
        let response = makeVideoRendererAgeResponse(renderer)
        let api = InnerTubeAPI()
        let group = try await api.parseVideoGroupForTesting(response, title: nil)
        let video = try #require(group.videos.first)

        #expect(video.publishedTimeText == "5 days ago")
        #expect(VideoPublicationFormatter.string(
            for: video,
            locale: Locale(identifier: "ru_RU")
        ) != "Дата неизвестна")
    }

    @Test("parseVideoRenderer without publishedTimeText leaves publishedAt nil")
    func videoRenderer_noPublishedTimeText_publishedAtIsNil() async throws {
        let response = makeVideoRendererAgeResponse(makeRenderer(publishedTimeText: nil))
        let api = InnerTubeAPI()
        let group = try await api.parseVideoGroupForTesting(response, title: nil)
        let video = try #require(group.videos.first, "Expected at least one video from response")
        #expect(video.publishedAt == nil,
                "publishedAt should be nil when publishedTimeText is absent from JSON")
    }
}

// MARK: - parseLockupViewModel publishedAt

@Suite("Task #97 — parseLockupViewModel publishedAt extraction")
struct LockupViewModelPublishAgeTests {

    /// Builds a minimal valid lockupViewModel with configurable metadataRows.
    private func makeLockup(metadataRows: [[String: Any]]) -> [String: Any] {
        [
            "rendererContext": [
                "commandContext": [
                    "onTap": [
                        "innertubeCommand": [
                            "watchEndpoint": ["videoId": "lockupvid"]
                        ]
                    ]
                ]
            ],
            "metadata": [
                "lockupMetadataViewModel": [
                    "title": ["content": "Lockup Video"],
                    "metadata": [
                        "contentMetadataViewModel": [
                            "metadataRows": metadataRows
                        ]
                    ]
                ]
            ],
            "contentImage": [
                "thumbnailViewModel": [
                    "image": ["thumbnails": [["url": "https://i.ytimg.com/vi/lockupvid/hqdefault.jpg"]]]
                ]
            ]
        ]
    }

    @Test("Lockup relative label does not become an exact date")
    func lockupViewModel_secondRow_populatesPublishedAt() async throws {
        let rows: [[String: Any]] = [
            // Row 0: channel name
            ["metadataParts": [["text": ["content": "Channel Name"]]]],
            // Row 1: view count + published date (both in same row — mirrors real YouTube layout)
            ["metadataParts": [
                ["text": ["content": "1.2M views"]],
                ["text": ["content": "2 years ago"]]
            ]]
        ]
        let response = makeLockupViewModelAgeResponse(makeLockup(metadataRows: rows))
        let api = InnerTubeAPI()
        let group = try await api.parseVideoGroupForTesting(response, title: nil)
        let video = try #require(group.videos.first, "Expected at least one video from lockupViewModel response")
        #expect(video.publishedAt == nil)
        #expect(video.publishedTimeText == "2 years ago")
    }

    @Test("Current lockupViewModel localized relative label is preserved")
    func lockupViewModel_localizedDateText() async throws {
        let rows: [[String: Any]] = [
            ["metadataParts": [["text": ["content": "Channel Name"]]]],
            ["metadataParts": [
                ["text": ["content": "1,2 млн просмотров"]],
                ["text": ["content": "3 дня назад"]],
            ]],
        ]
        let response = makeLockupViewModelAgeResponse(makeLockup(metadataRows: rows))
        let api = InnerTubeAPI()
        let group = try await api.parseVideoGroupForTesting(response, title: nil)
        let video = try #require(group.videos.first)

        #expect(video.publishedTimeText == "3 дня назад")
        #expect(VideoPublicationFormatter.string(
            for: video,
            locale: Locale(identifier: "ru_RU")
        ) == "3 дня назад")
    }

    @Test("parseLockupViewModel with no relative-date text leaves publishedAt nil")
    func lockupViewModel_noRelativeDate_publishedAtIsNil() async throws {
        let rows: [[String: Any]] = [
            ["metadataParts": [["text": ["content": "Channel Name"]]]],
            ["metadataParts": [["text": ["content": "1.2M views"]]]]
            // No relative date in any row
        ]
        let response = makeLockupViewModelAgeResponse(makeLockup(metadataRows: rows))
        let api = InnerTubeAPI()
        let group = try await api.parseVideoGroupForTesting(response, title: nil)
        let video = try #require(group.videos.first, "Expected at least one video from lockupViewModel response")
        #expect(video.publishedAt == nil,
                "publishedAt should be nil when no row contains a relative date string")
    }
}
