import Foundation
import Testing
@testable import iPocketTubeCore

// MARK: - LocalSubscriptionStoreTests

@Suite("Local Subscription Store")
struct LocalSubscriptionStoreTests {

    // MARK: - Helpers

    private func makeStore() -> LocalSubscriptionStore {
        LocalSubscriptionStore(suiteName: "test-\(UUID().uuidString)")
    }

    private func makeChannel(id: String = "UCtest123", title: String = "Test Channel") -> LocalChannel {
        LocalChannel(id: id, title: title, thumbnailURL: URL(string: "https://example.com/thumb.jpg"))
    }

    // MARK: - follow / isFollowing

    @Test("Following a channel marks it as followed")
    func followAndIsFollowing() async {
        let store = makeStore()
        let channel = makeChannel()
        await store.follow(channel)
        let following = await store.isFollowing(channel.id)
        #expect(following == true)
    }

    @Test("Unfollowed channel is not following")
    func notFollowingByDefault() async {
        let store = makeStore()
        let following = await store.isFollowing("UCnothere")
        #expect(following == false)
    }

    @Test("Following is idempotent — duplicate follow is a no-op")
    func followIdempotent() async {
        let store = makeStore()
        let channel = makeChannel()
        await store.follow(channel)
        await store.follow(channel)
        let all = await store.allChannels()
        #expect(all.count == 1)
    }

    // MARK: - unfollow

    @Test("Unfollow removes the channel")
    func unfollowRemoves() async {
        let store = makeStore()
        let channel = makeChannel()
        await store.follow(channel)
        await store.unfollow(channelId: channel.id)
        let following = await store.isFollowing(channel.id)
        #expect(following == false)
    }

    @Test("Unfollow on non-existent channel is a no-op")
    func unfollowNonExistent() async {
        let store = makeStore()
        // Should not crash
        await store.unfollow(channelId: "UCdoesnotexist")
        let all = await store.allChannels()
        #expect(all.isEmpty)
    }

    // MARK: - allChannels sort

    @Test("allChannels returns channels sorted alphabetically by title")
    func allChannelsSorted() async {
        let store = makeStore()
        await store.follow(makeChannel(id: "UC1", title: "Zebra Channel"))
        await store.follow(makeChannel(id: "UC2", title: "Apple Channel"))
        await store.follow(makeChannel(id: "UC3", title: "Mango Channel"))
        let all = await store.allChannels()
        #expect(all.map(\.title) == ["Apple Channel", "Mango Channel", "Zebra Channel"])
    }

    @Test("allChannelsSortedBySubscriptionDate returns channels newest-subscribed-first")
    func allChannelsSortedByDateDescending() async {
        let store = makeStore()
        var older = makeChannel(id: "UC1", title: "Older Channel")
        older.addedAt = Date(timeIntervalSinceReferenceDate: 1000)
        var newer = makeChannel(id: "UC2", title: "Newer Channel")
        newer.addedAt = Date(timeIntervalSinceReferenceDate: 3000)
        var middle = makeChannel(id: "UC3", title: "Middle Channel")
        middle.addedAt = Date(timeIntervalSinceReferenceDate: 2000)

        await store.follow(older)
        await store.follow(newer)
        await store.follow(middle)

        let sorted = await store.allChannelsSortedBySubscriptionDate()
        #expect(sorted.map(\.id) == ["UC2", "UC3", "UC1"])
    }

    // MARK: - updateMetadata

    @Test("updateMetadata refreshes title and thumbnail for followed channel")
    func updateMetadataUpdates() async {
        let store = makeStore()
        let channel = makeChannel(id: "UCupdate", title: "Old Title")
        await store.follow(channel)
        let newThumb = URL(string: "https://example.com/new-thumb.jpg")!
        await store.updateMetadata(channelId: "UCupdate", title: "New Title", thumbnailURL: newThumb)
        let all = await store.allChannels()
        let updated = all.first { $0.id == "UCupdate" }
        #expect(updated?.title == "New Title")
        #expect(updated?.thumbnailURL == newThumb)
    }

    @Test("updateMetadata is a no-op for non-followed channel")
    func updateMetadataNoOpForNonFollowed() async {
        let store = makeStore()
        // Should not crash and should not create an entry
        await store.updateMetadata(channelId: "UCnotfollowed", title: "Ghost", thumbnailURL: nil)
        let all = await store.allChannels()
        #expect(all.isEmpty)
    }

    // MARK: - Persistence round-trip

    @Test("Followed channel persists across store instances sharing the same suite")
    func persistenceRoundTrip() async {
        let suiteName = "test-persist-\(UUID().uuidString)"
        let store1 = LocalSubscriptionStore(suiteName: suiteName)
        let channel = makeChannel(id: "UCpersist", title: "Persistent Channel")
        await store1.follow(channel)

        // Create a new store instance backed by the same UserDefaults suite
        let store2 = LocalSubscriptionStore(suiteName: suiteName)
        let following = await store2.isFollowing("UCpersist")
        #expect(following == true)
    }

    // MARK: - toChannel conversion

    @Test("toChannel converts LocalChannel to Channel with isSubscribed = true")
    func toChannelConversion() {
        let local = makeChannel(id: "UCconv", title: "Converted")
        let channel = local.toChannel()
        #expect(channel.id == "UCconv")
        #expect(channel.title == "Converted")
        #expect(channel.isSubscribed == true)
    }
}
