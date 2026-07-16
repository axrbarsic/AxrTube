import Foundation
import Testing
@testable import SmartTubeIOSCore

@Suite("AxrTube audio-first flow")
struct AudioFirstFlowTests {
    private func video(
        publishedAt: Date? = nil,
        publishedTimeText: String? = nil,
        isShort: Bool = false
    ) -> Video {
        Video(
            id: "fixture",
            title: "Fixture",
            channelTitle: "Channel",
            publishedAt: publishedAt,
            publishedTimeText: publishedTimeText,
            isShort: isShort
        )
    }

    @Test("Normal and Shorts taps never create a fullscreen destination")
    func tapPolicyIsAlwaysMiniPlayer() {
        #expect(AudioFirstPresentationPolicy.destination(for: video()) == .miniPlayer)
        #expect(AudioFirstPresentationPolicy.destination(for: video(isShort: true)) == .miniPlayer)
    }

    @Test("Progressive playback starts after a safe prefix and before completion")
    func progressivePlaybackStartsBeforeHundredPercent() {
        var state = ProgressiveAudioStateMachine(initialBufferBytes: 512 * 1024)
        let startedTooEarly = state.receive(downloaded: 128 * 1024, expected: 4 * 1024 * 1024)
        #expect(!startedTooEarly)
        let startedAtThreshold = state.receive(downloaded: 256 * 1024, expected: 4 * 1024 * 1024)
        #expect(startedAtThreshold)
        #expect(state.downloadProgress < 1)
        let duplicateStart = state.receive(downloaded: 768 * 1024, expected: 4 * 1024 * 1024)
        #expect(!duplicateStart)
    }

    @Test("Seek is clamped to the downloaded region")
    func seekCannotOutrunCache() {
        var state = ProgressiveAudioStateMachine(initialBufferBytes: 1)
        _ = state.receive(downloaded: 1_000, expected: 10_000)
        #expect(state.clampedSeekTime(90, duration: 100) == 9.75)
    }

    @Test("Russian publication labels cover today yesterday relative and missing")
    func russianPublicationLabels() {
        let locale = Locale(identifier: "ru_RU")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        #expect(VideoPublicationFormatter.string(
            for: video(publishedAt: now.addingTimeInterval(-3_600)),
            now: now, locale: locale, calendar: calendar
        ) == "сегодня")
        #expect(VideoPublicationFormatter.string(
            for: video(publishedAt: now.addingTimeInterval(-86_400)),
            now: now, locale: locale, calendar: calendar
        ) == "вчера")
        #expect(VideoPublicationFormatter.string(
            for: video(publishedAt: now.addingTimeInterval(-3 * 86_400), publishedTimeText: "3 days ago"),
            now: now, locale: locale, calendar: calendar
        ).contains("3") == true)
        #expect(VideoPublicationFormatter.string(
            for: video(), now: now, locale: locale, calendar: calendar
        ) == "Дата неизвестна")
    }
}

@Suite("Ad renderer exclusion")
struct AdRendererExclusionTests {
    @Test("Flat parser never descends into promoted renderer payloads")
    func flatParserDropsNestedAdVideo() async throws {
        let api = InnerTubeAPI()
        let json: [String: Any] = [
            "contents": [
                ["adSlotRenderer": ["videoRenderer": videoRenderer(id: "ad-video")]],
                ["videoRenderer": videoRenderer(id: "real-video")],
            ]
        ]
        let group = try await api.parseVideoGroupForTesting(json, title: "Fixture")
        #expect(group.videos.map(\.id) == ["real-video"])
    }

    private func videoRenderer(id: String) -> [String: Any] {
        [
            "videoId": id,
            "title": ["simpleText": id],
            "ownerText": ["simpleText": "Channel"],
            "thumbnail": ["thumbnails": [["url": "https://example.invalid/thumb.jpg"]]],
            "publishedTimeText": ["simpleText": "3 days ago"],
        ]
    }
}
