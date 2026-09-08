import Foundation
import Testing
@testable import iPocketTubeCore

@Suite("Pinned channels") @MainActor
struct PinnedChannelStoreTests {
    @Test func pinsPersistAndSurviveIncompleteResponses() throws {
        let suite = "PinnedChannelsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PinnedChannelStore(defaults: defaults)
        let favorite = Channel(id: "UCfavorite", title: "Майкл Наки")
        let other = Channel(id: "UCother", title: "Альфа")
        store.toggle(favorite)
        let restored = PinnedChannelStore(defaults: defaults)
        #expect(restored.orderedChannels([other]).map(\.id) == [favorite.id, other.id])
        #expect(restored.orderedChannels([favorite, favorite, other]).count == 2)
        restored.toggle(favorite)
        #expect(restored.orderedChannels([other]).map(\.id) == [other.id])
        #expect(PinnedChannelStore(defaults: defaults).channels.isEmpty)
    }
}
