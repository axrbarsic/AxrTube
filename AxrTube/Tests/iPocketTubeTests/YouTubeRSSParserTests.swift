import Foundation
import Testing
@testable import iPocketTubeCore

// MARK: - YouTubeRSSParserTests

@Suite("YouTube RSS Parser")
struct YouTubeRSSParserTests {

    // MARK: - Sample feeds

    private static let nominalFeed = """
    <?xml version="1.0" encoding="UTF-8"?>
    <feed xmlns:yt="http://www.youtube.com/xml/schemas/2015"
          xmlns:media="http://search.yahoo.com/mrss/"
          xmlns="http://www.w3.org/2005/Atom">
      <title>Test Channel</title>
      <author>
        <name>Test Channel</name>
      </author>
      <entry>
        <id>yt:video:abc1234ABCD</id>
        <yt:videoId>abc1234ABCD</yt:videoId>
        <title>First Video Title</title>
        <published>2024-03-15T18:00:00+00:00</published>
        <author>
          <name>Test Channel</name>
        </author>
        <media:group>
          <media:thumbnail url="https://i.ytimg.com/vi/abc1234ABCD/hqdefault.jpg" width="480" height="360"/>
          <media:statistics views="12345"/>
        </media:group>
      </entry>
      <entry>
        <id>yt:video:xyz9876WXYZ</id>
        <yt:videoId>xyz9876WXYZ</yt:videoId>
        <title>Second Video Title</title>
        <published>2024-03-10T12:00:00+00:00</published>
        <author>
          <name>Test Channel</name>
        </author>
        <media:group>
          <media:thumbnail url="https://i.ytimg.com/vi/xyz9876WXYZ/hqdefault.jpg" width="480" height="360"/>
          <media:statistics views="999"/>
        </media:group>
      </entry>
    </feed>
    """

    private static let emptyFeed = """
    <?xml version="1.0" encoding="UTF-8"?>
    <feed xmlns:yt="http://www.youtube.com/xml/schemas/2015"
          xmlns="http://www.w3.org/2005/Atom">
      <title>Empty Channel</title>
      <author><name>Empty Channel</name></author>
    </feed>
    """

    private static let malformedFeed = """
    <?xml version="1.0"?>
    <feed>
      <entry>
        <yt:videoId>partial001</yt:videoId>
        <title>Partial video
    """  // intentionally truncated / malformed

    // MARK: - Nominal parsing

    @Test("Parses two entries from a nominal feed")
    func parsesEntries() {
        let data = Self.nominalFeed.data(using: .utf8)!
        let result = parseYouTubeRSS(data, channelId: "UCtest")
        #expect(result.videos.count == 2)
    }

    @Test("Extracts correct videoId from first entry")
    func extractsVideoId() {
        let data = Self.nominalFeed.data(using: .utf8)!
        let result = parseYouTubeRSS(data, channelId: "UCtest")
        #expect(result.videos.first?.id == "abc1234ABCD")
    }

    @Test("Extracts correct title from first entry")
    func extractsTitle() {
        let data = Self.nominalFeed.data(using: .utf8)!
        let result = parseYouTubeRSS(data, channelId: "UCtest")
        #expect(result.videos.first?.title == "First Video Title")
    }

    @Test("Extracts publishedAt date from first entry")
    func extractsPublishedAt() {
        let data = Self.nominalFeed.data(using: .utf8)!
        let result = parseYouTubeRSS(data, channelId: "UCtest")
        #expect(result.videos.first?.publishedAt != nil)
    }

    @Test("Extracts thumbnailURL from first entry")
    func extractsThumbnailURL() {
        let data = Self.nominalFeed.data(using: .utf8)!
        let result = parseYouTubeRSS(data, channelId: "UCtest")
        let expected = URL(string: "https://i.ytimg.com/vi/abc1234ABCD/hqdefault.jpg")
        #expect(result.videos.first?.thumbnailURL == expected)
    }

    @Test("Extracts viewCount from first entry")
    func extractsViewCount() {
        let data = Self.nominalFeed.data(using: .utf8)!
        let result = parseYouTubeRSS(data, channelId: "UCtest")
        #expect(result.videos.first?.viewCount == 12_345)
    }

    @Test("Extracts channel name from feed-level author")
    func extractsChannelName() {
        let data = Self.nominalFeed.data(using: .utf8)!
        let result = parseYouTubeRSS(data, channelId: "UCtest")
        #expect(result.channelName == "Test Channel")
    }

    @Test("channelId is set correctly on parsed videos")
    func channelIdSet() {
        let data = Self.nominalFeed.data(using: .utf8)!
        let result = parseYouTubeRSS(data, channelId: "UCtest123")
        #expect(result.videos.allSatisfy { $0.channelId == "UCtest123" })
    }

    // MARK: - Empty feed

    @Test("Empty feed returns no videos without crashing")
    func emptyFeedReturnsEmpty() {
        let data = Self.emptyFeed.data(using: .utf8)!
        let result = parseYouTubeRSS(data, channelId: "UCempty")
        #expect(result.videos.isEmpty)
    }

    // MARK: - Malformed feed

    @Test("Malformed XML returns partial or empty results without crashing")
    func malformedXMLDoesNotCrash() {
        let data = Self.malformedFeed.data(using: .utf8)!
        // Should not crash — may return partial or empty
        let result = parseYouTubeRSS(data, channelId: "UCbad")
        #expect(result.videos.count >= 0)   // any count is acceptable
    }

    // MARK: - YouTubeRSS URL helpers

    @Test("UC prefix is converted to UU for uploads playlist ID")
    func uploadsPlaylistId() {
        let playlistId = YouTubeRSS.uploadsPlaylistId(from: "UCBcRF18a7Qf58cCRy5xuWwQ")
        #expect(playlistId == "UUBcRF18a7Qf58cCRy5xuWwQ")
    }

    @Test("Non-UC channel ID passes through unchanged")
    func nonUCPassThrough() {
        let playlistId = YouTubeRSS.uploadsPlaylistId(from: "PLtest123")
        #expect(playlistId == "PLtest123")
    }

    @Test("feedURL contains the uploads playlist ID")
    func feedURLContainsPlaylistId() {
        let url = YouTubeRSS.feedURL(for: "UCBcRF18a7Qf58cCRy5xuWwQ")
        #expect(url.absoluteString.contains("playlist_id=UUBcRF18a7Qf58cCRy5xuWwQ"))
    }

    @Test("fallbackFeedURL contains the channel ID")
    func fallbackFeedURLContainsChannelId() {
        let url = YouTubeRSS.fallbackFeedURL(for: "UCBcRF18a7Qf58cCRy5xuWwQ")
        #expect(url.absoluteString.contains("channel_id=UCBcRF18a7Qf58cCRy5xuWwQ"))
    }

    @Test("shortsPlaylistId converts UCxxxx to UUSHxxxx")
    func shortsPlaylistIdDerivation() {
        let id = YouTubeRSS.shortsPlaylistId(from: "UCBcRF18a7Qf58cCRy5xuWwQ")
        #expect(id == "UUSHBcRF18a7Qf58cCRy5xuWwQ")
    }

    @Test("shortsPlaylistId passes through non-UC channel ID unchanged")
    func shortsPlaylistIdNonUCChannelPassthrough() {
        let id = YouTubeRSS.shortsPlaylistId(from: "PLtest123")
        #expect(id == "PLtest123")
    }

    @Test("shortsFeedURL contains the UUSH playlist ID")
    func shortsFeedURLContainsShortsPlaylistId() {
        let url = YouTubeRSS.shortsFeedURL(for: "UCBcRF18a7Qf58cCRy5xuWwQ")
        #expect(url.absoluteString.contains("playlist_id=UUSHBcRF18a7Qf58cCRy5xuWwQ"))
    }
}
