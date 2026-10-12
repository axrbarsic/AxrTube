import Foundation
import Testing
@testable import iPocketTubeCore

@Suite("YouTube-style card metadata")
struct YouTubeMetaFormatterTests {
    @Test func viewCountsUseRussianPluralsAndAbbreviations() {
        #expect(YouTubeMetaFormatter.views(1) == "1 просмотр")
        #expect(YouTubeMetaFormatter.views(3) == "3 просмотра")
        #expect(YouTubeMetaFormatter.views(11) == "11 просмотров")
        #expect(YouTubeMetaFormatter.views(21) == "21 просмотр")
        #expect(YouTubeMetaFormatter.views(345) == "345 просмотров")
        #expect(YouTubeMetaFormatter.views(1_200) == "1,2 тыс. просмотров")
        #expect(YouTubeMetaFormatter.views(15_000) == "15 тыс. просмотров")
        #expect(YouTubeMetaFormatter.views(1_250_000) == "1,2 млн просмотров")
        #expect(YouTubeMetaFormatter.views(3_400_000_000) == "3,4 млрд просмотров")
    }

    @Test func metaLineSkipsMissingParts() {
        let video = Video(id: "x", title: "t", channelTitle: "Канал")
        #expect(YouTubeMetaFormatter.metaLine(for: video, published: nil) == "Канал")
        var withViews = video
        withViews.viewCount = 1_200
        #expect(YouTubeMetaFormatter.metaLine(for: withViews, published: "2 дня назад")
            == "Канал · 1,2 тыс. просмотров · 2 дня назад")
    }

    @Test func liveVideoShowsWatchingLabelInsteadOfViews() {
        var video = Video(id: "x", title: "t", channelTitle: "Канал")
        video.isLive = true
        video.viewCount = 500
        #expect(YouTubeMetaFormatter.metaLine(for: video, published: nil) == "Канал · 500 зрителей")
    }
}
