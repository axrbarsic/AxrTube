import Foundation
import Testing
@testable import iPocketTubeCore

@Suite("Channel avatars for cards")
struct ChannelAvatarTests {
    @Test func readsWebVideoRendererAvatar() {
        let renderer: [String: Any] = ["channelThumbnailSupportedRenderers": ["channelThumbnailWithLinkRenderer": [
            "thumbnail": ["thumbnails": [["url": "//yt3.ggpht.com/small"], ["url": "//yt3.ggpht.com/big"]]],
        ]]]
        #expect(ChannelAvatarExtractor.avatarURL(in: renderer)?.absoluteString == "https://yt3.ggpht.com/big")
    }

    @Test func readsLockupAvatarViewModel() {
        let renderer: [String: Any] = ["metadata": ["lockupMetadataViewModel": ["image": ["decoratedAvatarViewModel": [
            "avatar": ["avatarViewModel": ["image": ["sources": [["url": "https://yt3.ggpht.com/a"]]]]],
        ]]]]]
        #expect(ChannelAvatarExtractor.avatarURL(in: renderer)?.absoluteString == "https://yt3.ggpht.com/a")
    }

    @Test func missingAvatarIsNil() {
        #expect(ChannelAvatarExtractor.avatarURL(in: ["title": "x"]) == nil)
    }

    @Test func cacheFetchesEachChannelOnce() async {
        let cache = ChannelAvatarCache()
        let counter = Counter()
        let url = URL(string: "https://yt3.ggpht.com/c")!
        async let a = cache.avatar(for: "UC1") { await counter.bump(); return url }
        async let b = cache.avatar(for: "UC1") { await counter.bump(); return url }
        let results = await [a, b]
        let again = await cache.avatar(for: "UC1") { await counter.bump(); return nil }
        #expect(results == [url, url])
        #expect(again == url)
        #expect(await counter.value == 1)
    }

    @Test func avatarSurvivesCodableCache() throws {
        var video = Video(id: "v", title: "t", channelTitle: "c")
        video.channelAvatarURL = URL(string: "https://yt3.ggpht.com/z")
        let decoded = try JSONDecoder().decode(Video.self, from: JSONEncoder().encode(video))
        #expect(decoded.channelAvatarURL == video.channelAvatarURL)
        let old = try JSONDecoder().decode(Video.self, from: Data(#"{"id":"v","title":"t","channelTitle":"c","isLive":false,"isUpcoming":false,"isShort":false,"hasPortraitThumbnail":false,"badges":[]}"#.utf8))
        #expect(old.channelAvatarURL == nil)
    }
}

private actor Counter {
    var value = 0
    func bump() { value += 1 }
}

@Suite("Search channel results")
struct SearchChannelParserTests {
    @Test func readsChannelRenderers() {
        let json: [String: Any] = ["contents": ["twoColumnSearchResultsRenderer": ["primaryContents": ["sectionListRenderer": ["contents": [
            ["itemSectionRenderer": ["contents": [
                ["channelRenderer": [
                    "channelId": "UC1",
                    "title": ["simpleText": "Канал"],
                    "thumbnail": ["thumbnails": [["url": "//yt3.ggpht.com/x"]]],
                    "subscriberCountText": ["simpleText": "@kanal"],
                    "videoCountText": ["simpleText": "1,2 млн подписчиков"],
                ]],
                ["videoRenderer": ["videoId": "v1"]],
                ["channelRenderer": ["channelId": "UC1", "title": ["simpleText": "дубль"]]],
            ]]],
        ]]]]]]
        let channels = SearchChannelParser.channels(in: json, text: { $0["simpleText"] as? String })
        #expect(channels.map(\.id) == ["UC1"])
        #expect(channels.first?.title == "Канал")
        #expect(channels.first?.thumbnailURL?.absoluteString == "https://yt3.ggpht.com/x")
        #expect(channels.first?.subscriberCount == "@kanal • 1,2 млн подписчиков")
    }
}
