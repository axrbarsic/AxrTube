import Foundation
import Testing
@testable import iPocketTubeCore

@MainActor
@Suite("YouTube Home refresh semantics")
struct YouTubeHomeFeedModelTests {
    private func video(_ id: String, short: Bool = false) -> Video {
        Video(id: id, title: id, channelTitle: "c", isShort: short)
    }

    private func rows(_ ids: [String], token: String? = nil) -> [VideoGroup] {
        [VideoGroup(title: "Home", videos: ids.map { video($0) }, nextPageToken: token)]
    }

    private func settle(_ model: YouTubeHomeFeedModel) async {
        for _ in 0..<50 where model.isLoading || model.isLoadingMore {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func firstLoadKeepsServiceOrder() async {
        let api = MockInnerTubeAPI()
        api.homeRowsResult = rows(["c", "a", "b"])
        let model = YouTubeHomeFeedModel(api: api)
        await model.refresh()
        #expect(model.videos.map(\.id) == ["c", "a", "b"])
    }

    @Test func refreshReplacesWholeFeedAndDropsAppendedPages() async {
        let api = MockInnerTubeAPI()
        api.homeRowsResult = rows(["a", "b"], token: "t1")
        let model = YouTubeHomeFeedModel(api: api)
        await model.refresh()
        api.homeRowsResult = rows(["c"])
        model.loadMore()
        await settle(model)
        #expect(model.videos.map(\.id) == ["a", "b", "c"])

        api.homeRowsResult = rows(["x", "y"], token: "t2")
        let before = model.replacementID
        await model.refresh()
        #expect(model.videos.map(\.id) == ["x", "y"])
        #expect(model.replacementID == before + 1)
        #expect(model.hasMore)
    }

    @Test func refreshRequestsFirstPageWithoutContinuation() async {
        let api = MockInnerTubeAPI()
        api.homeRowsResult = rows(["a"], token: "t1")
        let model = YouTubeHomeFeedModel(api: api)
        await model.refresh()
        await model.refresh()
        let tokens = api.calls.filter { $0.method == "fetchHomeRows" }.map(\.args)
        #expect(tokens == [["nil"], ["nil"]])
    }

    @Test func failedRefreshKeepsVisibleFeed() async {
        let api = MockInnerTubeAPI()
        api.homeRowsResult = rows(["a", "b"])
        let model = YouTubeHomeFeedModel(api: api)
        await model.refresh()
        api.errorToThrow = URLError(.notConnectedToInternet)
        await model.refresh()
        #expect(model.videos.map(\.id) == ["a", "b"])
        #expect(model.errorMessage != nil)
    }

    @Test func continuationAppendsOnlyNewItems() async {
        let api = MockInnerTubeAPI()
        api.homeRowsResult = rows(["a", "b"], token: "t1")
        let model = YouTubeHomeFeedModel(api: api)
        await model.refresh()
        api.homeRowsResult = rows(["b", "c"], token: "t1")
        model.loadMore()
        await settle(model)
        #expect(model.videos.map(\.id) == ["a", "b", "c"])
        #expect(!model.hasMore)
    }

    @Test func shortsAreSeparatedFromRegularVideos() async {
        let api = MockInnerTubeAPI()
        api.homeRowsResult = [VideoGroup(videos: [video("a"), video("s", short: true), video("b")])]
        let model = YouTubeHomeFeedModel(api: api)
        await model.refresh()
        #expect(model.regularVideos.map(\.id) == ["a", "b"])
        #expect(model.shorts.map(\.id) == ["s"])
    }

    @Test func staleFeedReloadsOnlyAfterThreshold() async {
        let api = MockInnerTubeAPI()
        api.homeRowsResult = rows(["a"])
        let model = YouTubeHomeFeedModel(api: api)
        await model.refresh()
        let loaded = model.loadedAt ?? Date()
        model.refreshIfStale(threshold: 60, now: loaded.addingTimeInterval(30))
        #expect(!model.isLoading)
        model.refreshIfStale(threshold: 60, now: loaded.addingTimeInterval(120))
        #expect(model.isLoading)
        await settle(model)
    }

    @Test func chipLoadsDestinationFeed() async {
        let api = MockInnerTubeAPI()
        api.homeRowsResult = rows(["a"])
        api.musicResult = VideoGroup(videos: [video("m1"), video("m2")])
        let model = YouTubeHomeFeedModel(api: api)
        await model.refresh()
        model.select(.music)
        await settle(model)
        #expect(model.videos.map(\.id) == ["m1", "m2"])
        #expect(!model.hasMore)
    }
}

@Suite("YouTube appearance setting")
struct AppearanceSettingTests {
    @Test func defaultsToDeviceAppearanceAndRoundTrips() throws {
        var settings = AppSettings()
        #expect(settings.appearance == .system)
        #expect(settings.appearance.colorScheme == nil)
        settings.appearance = .light
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded.appearance == .light)
    }

    @Test func oldStoresWithoutAppearanceUseDevice() throws {
        let data = Data(#"{"themeName":"Matrix"}"#.utf8)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        #expect(decoded.appearance == .system)
    }
}
