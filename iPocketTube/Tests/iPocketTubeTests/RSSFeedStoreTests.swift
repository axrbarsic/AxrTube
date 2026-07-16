import Foundation
import Testing
@testable import iPocketTubeCore

// MARK: - RSSFeedStoreTests

@Suite("RSSFeedStore")
struct RSSFeedStoreTests {

    private func makeStore() -> RSSFeedStore {
        RSSFeedStore(suiteName: "test-rss-\(UUID().uuidString)")
    }

    private func makeFeed(title: String = "Test Feed", urlString: String = "https://www.youtube.com/feeds/videos.xml?channel_id=UCtest") -> RSSFeedInfo {
        RSSFeedInfo(title: title, feedURL: URL(string: urlString)!)
    }

    // MARK: - addFeed

    @Test func addFeed_storesPersistently() async {
        let store = makeStore()
        let feed = makeFeed()
        await store.addFeed(feed)
        let all = await store.allFeeds()
        #expect(all.count == 1)
        #expect(all.first?.title == "Test Feed")
    }

    @Test func addFeed_idempotentByURL() async {
        let store = makeStore()
        let feed1 = makeFeed()
        let feed2 = RSSFeedInfo(title: "Duplicate", feedURL: URL(string: "https://www.youtube.com/feeds/videos.xml?channel_id=UCtest")!)
        await store.addFeed(feed1)
        await store.addFeed(feed2)
        let all = await store.allFeeds()
        // Same feedURL → second add is a no-op
        #expect(all.count == 1)
        #expect(all.first?.title == "Test Feed")
    }

    @Test func addFeed_differentURLsStoredSeparately() async {
        let store = makeStore()
        let feed1 = makeFeed(title: "Feed A", urlString: "https://www.youtube.com/feeds/videos.xml?channel_id=UC111")
        let feed2 = makeFeed(title: "Feed B", urlString: "https://www.youtube.com/feeds/videos.xml?channel_id=UC222")
        await store.addFeed(feed1)
        await store.addFeed(feed2)
        let all = await store.allFeeds()
        #expect(all.count == 2)
    }

    // MARK: - removeFeed

    @Test func removeFeed_byId_removesFeed() async {
        let store = makeStore()
        let feed = makeFeed()
        await store.addFeed(feed)
        await store.removeFeed(id: feed.id)
        let all = await store.allFeeds()
        #expect(all.isEmpty)
    }

    @Test func removeFeed_unknownId_isNoop() async {
        let store = makeStore()
        let feed = makeFeed()
        await store.addFeed(feed)
        await store.removeFeed(id: UUID())  // random unknown ID
        let all = await store.allFeeds()
        #expect(all.count == 1)
    }

    // MARK: - setActive

    @Test func setActive_false_disablesFeed() async {
        let store = makeStore()
        let feed = makeFeed()
        await store.addFeed(feed)
        await store.setActive(feed.id, false)
        let all = await store.allFeeds()
        #expect(all.first?.isActive == false)
    }

    @Test func setActive_true_enablesFeed() async {
        let store = makeStore()
        let feed = RSSFeedInfo(title: "Feed", feedURL: URL(string: "https://www.youtube.com/feeds/videos.xml?channel_id=UCtest")!, isActive: false)
        await store.addFeed(feed)
        await store.setActive(feed.id, true)
        let all = await store.allFeeds()
        #expect(all.first?.isActive == true)
    }

    // MARK: - RSSFeedInfo helpers

    @Test func channelId_extractedFromFeedURL() {
        let url = URL(string: "https://www.youtube.com/feeds/videos.xml?channel_id=UCabcdef12345")!
        #expect(RSSFeedInfo.channelId(from: url) == "UCabcdef12345")
    }

    @Test func channelId_returnsNil_forNonFeedURL() {
        let url = URL(string: "https://www.youtube.com/channel/UCabcdef12345")!
        #expect(RSSFeedInfo.channelId(from: url) == nil)
    }

    @Test func isYouTubeRSSFeed_returnsTrueForFeedURL() {
        let url = URL(string: "https://www.youtube.com/feeds/videos.xml?channel_id=UCtest")!
        #expect(RSSFeedInfo.isYouTubeRSSFeed(url) == true)
    }

    @Test func isYouTubeRSSFeed_returnsFalseForChannelURL() {
        let url = URL(string: "https://www.youtube.com/channel/UCtest")!
        #expect(RSSFeedInfo.isYouTubeRSSFeed(url) == false)
    }

    @Test func feedURL_buildsCorrectURL() {
        let url = RSSFeedInfo.feedURL(for: "UCtest123")
        #expect(url?.absoluteString == "https://www.youtube.com/feeds/videos.xml?channel_id=UCtest123")
    }
}
