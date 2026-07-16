import Foundation
import Testing
@testable import iPocketTubeCore

// MARK: - HideShortsFilterTests
//
// Unit-tests the `hideShorts` filter predicate used in SearchView,
// LibraryView, ChannelView, and RSSFeedsView:
//
//   videos.filter { !settings.hideShorts || !$0.isShort }
//
// All assertions are pure value transforms — no SwiftUI, no network.

@Suite("Hide Shorts filter predicate")
struct HideShortsFilterTests {

    // MARK: - Helpers

    private func makeVideo(id: String, isShort: Bool) -> Video {
        Video(id: id, title: id, channelTitle: "ch", isShort: isShort)
    }

    /// Applies the same predicate used in the fixed views.
    private func apply(hideShorts: Bool, to videos: [Video]) -> [Video] {
        videos.filter { !hideShorts || !$0.isShort }
    }

    // MARK: - hideShorts == false

    @Test("When hideShorts is false, all videos are returned including Shorts")
    func hideShortsDisabledPassesAll() {
        let videos = [
            makeVideo(id: "a", isShort: false),
            makeVideo(id: "b", isShort: true),
            makeVideo(id: "c", isShort: false),
            makeVideo(id: "d", isShort: true),
        ]
        let result = apply(hideShorts: false, to: videos)
        #expect(result.count == 4)
        #expect(result.map(\.id) == ["a", "b", "c", "d"])
    }

    // MARK: - hideShorts == true

    @Test("When hideShorts is true, Short videos are removed")
    func hideShortsEnabledRemovesShorts() {
        let videos = [
            makeVideo(id: "a", isShort: false),
            makeVideo(id: "b", isShort: true),
            makeVideo(id: "c", isShort: false),
            makeVideo(id: "d", isShort: true),
        ]
        let result = apply(hideShorts: true, to: videos)
        #expect(result.count == 2)
        #expect(result.map(\.id) == ["a", "c"])
    }

    @Test("When hideShorts is true and all videos are Shorts, result is empty")
    func hideShortsEnabledAllShortsReturnsEmpty() {
        let videos = [
            makeVideo(id: "a", isShort: true),
            makeVideo(id: "b", isShort: true),
        ]
        let result = apply(hideShorts: true, to: videos)
        #expect(result.isEmpty)
    }

    @Test("When hideShorts is true and no videos are Shorts, all are returned")
    func hideShortsEnabledNoShortsPassesAll() {
        let videos = [
            makeVideo(id: "a", isShort: false),
            makeVideo(id: "b", isShort: false),
        ]
        let result = apply(hideShorts: true, to: videos)
        #expect(result.count == 2)
    }

    @Test("Empty input produces empty output regardless of hideShorts")
    func emptyInputAlwaysEmpty() {
        #expect(apply(hideShorts: false, to: []).isEmpty)
        #expect(apply(hideShorts: true,  to: []).isEmpty)
    }

    // MARK: - AppSettings default

    @Test("AppSettings default keeps Shorts hidden")
    func appSettingsDefaultHidesShorts() {
        let settings = AppSettings()
        #expect(settings.hideShorts)
        #expect(!settings.showShorts)
    }

    // MARK: - PlaylistView (task #46)

    @Test("PlaylistView: mixed playlist shows all videos when hideShorts is false")
    func playlistViewShowsAllWhenHideShortsDisabled() {
        let videos = [
            makeVideo(id: "v1", isShort: false),
            makeVideo(id: "s1", isShort: true),
            makeVideo(id: "v2", isShort: false),
            makeVideo(id: "s2", isShort: true),
        ]
        // displayVideos computed property: filter { !hideShorts || !$0.isShort }
        let result = apply(hideShorts: false, to: videos)
        #expect(result.count == 4, "All 4 videos must appear when hideShorts is off")
    }

    @Test("PlaylistView: mixed playlist hides shorts when hideShorts is true")
    func playlistViewHidesShortsWhenEnabled() {
        let videos = [
            makeVideo(id: "v1", isShort: false),
            makeVideo(id: "s1", isShort: true),
            makeVideo(id: "v2", isShort: false),
            makeVideo(id: "s2", isShort: true),
        ]
        let result = apply(hideShorts: true, to: videos)
        #expect(result.count == 2)
        #expect(result.map(\.id) == ["v1", "v2"], "Only non-shorts must remain when hideShorts is on")
    }

    // MARK: - Task #55: parseLockupViewModel sets isShort correctly

    /// Builds a minimal lockupViewModel JSON blob with a reelWatchEndpoint and confirms
    /// the parser marks the resulting Video as isShort == true.
    @Test("lockupViewModel with reelWatchEndpoint is parsed as a Short")
    func lockupViewModelReelEndpoint_isShortTrue() async throws {
        let lockupVM: [String: Any] = [
            "rendererContext": [
                "commandContext": [
                    "onTap": [
                        "innertubeCommand": [
                            "reelWatchEndpoint": ["videoId": "SHORT_ID_1"]
                        ]
                    ]
                ]
            ]
        ]
        let json: [String: Any] = [
            "items": [["lockupViewModel": lockupVM]]
        ]
        let api = InnerTubeAPI()
        let group = try await api.parseVideoGroupForTesting(json, title: nil)
        #expect(group.videos.count == 1, "Short should be parsed from reelWatchEndpoint")
        #expect(group.videos.first?.id == "SHORT_ID_1")
        #expect(group.videos.first?.isShort == true, "Video from reelWatchEndpoint must have isShort == true")
    }

    /// Builds a minimal lockupViewModel JSON blob with a watchEndpoint and confirms
    /// the parser marks the resulting Video as isShort == false.
    @Test("lockupViewModel with watchEndpoint is parsed as a regular video")
    func lockupViewModelWatchEndpoint_isShortFalse() async throws {
        let lockupVM: [String: Any] = [
            "rendererContext": [
                "commandContext": [
                    "onTap": [
                        "innertubeCommand": [
                            "watchEndpoint": ["videoId": "VIDEO_ID_1"]
                        ]
                    ]
                ]
            ]
        ]
        let json: [String: Any] = [
            "items": [["lockupViewModel": lockupVM]]
        ]
        let api = InnerTubeAPI()
        let group = try await api.parseVideoGroupForTesting(json, title: nil)
        #expect(group.videos.count == 1, "Regular video should be parsed from watchEndpoint")
        #expect(group.videos.first?.id == "VIDEO_ID_1")
        #expect(group.videos.first?.isShort == false, "Video from watchEndpoint must have isShort == false")
    }

    /// Confirms that a lockupViewModel Short is filtered out when hideShorts is true.
    @Test("lockupViewModel Short is hidden when hideShorts is enabled")
    func lockupViewModelShort_hiddenWhenHideShortsEnabled() async throws {
        let shortVM: [String: Any] = [
            "rendererContext": [
                "commandContext": [
                    "onTap": [
                        "innertubeCommand": [
                            "reelWatchEndpoint": ["videoId": "SHORT_ID_2"]
                        ]
                    ]
                ]
            ]
        ]
        let videoVM: [String: Any] = [
            "rendererContext": [
                "commandContext": [
                    "onTap": [
                        "innertubeCommand": [
                            "watchEndpoint": ["videoId": "VIDEO_ID_2"]
                        ]
                    ]
                ]
            ]
        ]
        let json: [String: Any] = [
            "items": [
                ["lockupViewModel": shortVM],
                ["lockupViewModel": videoVM],
            ]
        ]
        let api = InnerTubeAPI()
        let group = try await api.parseVideoGroupForTesting(json, title: nil)
        let visible = apply(hideShorts: true, to: group.videos)
        #expect(visible.count == 1)
        #expect(visible.first?.id == "VIDEO_ID_2", "Only the regular video should survive the filter")
    }
}

// MARK: - History exemption tests

extension HideShortsFilterTests {

    @Test("History section follows the global Shorts setting")
    func historyShortFilteredWhenHideShortsEnabled() {
        let videos = [
            makeVideo(id: "regular1", isShort: false),
            makeVideo(id: "short1",   isShort: true),
        ]
        let result = FeedCatalogPolicy.visibleVideos(videos, showShorts: false)
        #expect(result.map(\.id) == ["regular1"])
    }

    @Test("Subscriptions section: Shorts ARE filtered when hideShorts is enabled")
    func subscriptionsShortFilteredWhenHideShortsEnabled() {
        let videos = [
            makeVideo(id: "regular1", isShort: false),
            makeVideo(id: "short1",   isShort: true),
        ]
        let result = FeedCatalogPolicy.visibleVideos(videos, showShorts: false)
        #expect(result.count == 1)
        #expect(result.first?.id == "regular1")
    }
}

// MARK: - Task #231: parsePlaylistVideoRenderer isShort detection (BUG-019)

extension HideShortsFilterTests {

    private func playlistVideoRendererJSON(videoId: String, extras: [String: Any] = [:]) -> [String: Any] {
        var renderer: [String: Any] = [
            "videoId": videoId,
            "title": ["simpleText": videoId],
            "shortBylineText": ["runs": [["text": "Channel"]]],
            "thumbnail": ["thumbnails": [["url": "https://example.com/thumb.jpg", "width": 120, "height": 90]]],
        ]
        for (k, v) in extras { renderer[k] = v }
        return ["playlistVideoRenderer": renderer]
    }

    @Test("playlistVideoRenderer with reelWatchEndpoint is parsed as a Short")
    func playlistVideoRendererReelEndpoint_isShortTrue() async throws {
        let json: [String: Any] = [
            "items": [
                playlistVideoRendererJSON(videoId: "SHORT_PV_1", extras: [
                    "navigationEndpoint": ["reelWatchEndpoint": ["videoId": "SHORT_PV_1"]],
                    "lengthText": ["simpleText": "0:30"]
                ])
            ]
        ]
        let api = InnerTubeAPI()
        let group = try await api.parseVideoGroupForTesting(json, title: nil)
        #expect(group.videos.count == 1)
        #expect(group.videos.first?.id == "SHORT_PV_1")
        #expect(group.videos.first?.isShort == true, "playlistVideoRenderer with reelWatchEndpoint must be isShort")
    }

    @Test("playlistVideoRenderer with watchEndpoint is parsed as a regular video")
    func playlistVideoRendererWatchEndpoint_isShortFalse() async throws {
        let json: [String: Any] = [
            "items": [
                playlistVideoRendererJSON(videoId: "VIDEO_PV_1", extras: [
                    "navigationEndpoint": ["watchEndpoint": ["videoId": "VIDEO_PV_1"]],
                    "lengthText": ["simpleText": "5:00"]
                ])
            ]
        ]
        let api = InnerTubeAPI()
        let group = try await api.parseVideoGroupForTesting(json, title: nil)
        #expect(group.videos.count == 1)
        #expect(group.videos.first?.id == "VIDEO_PV_1")
        #expect(group.videos.first?.isShort == false, "playlistVideoRenderer with watchEndpoint must not be isShort")
    }

    @Test("playlistVideoRenderer Short is hidden when hideShorts is enabled")
    func playlistVideoRendererShort_hiddenWhenHideShortsEnabled() async throws {
        let json: [String: Any] = [
            "items": [
                playlistVideoRendererJSON(videoId: "SHORT_PV_2", extras: [
                    "navigationEndpoint": ["reelWatchEndpoint": ["videoId": "SHORT_PV_2"]],
                    "lengthText": ["simpleText": "0:45"]
                ]),
                playlistVideoRendererJSON(videoId: "VIDEO_PV_2", extras: [
                    "navigationEndpoint": ["watchEndpoint": ["videoId": "VIDEO_PV_2"]],
                    "lengthText": ["simpleText": "10:00"]
                ])
            ]
        ]
        let api = InnerTubeAPI()
        let group = try await api.parseVideoGroupForTesting(json, title: nil)
        let visible = apply(hideShorts: true, to: group.videos)
        #expect(visible.count == 1)
        #expect(visible.first?.id == "VIDEO_PV_2", "Only regular video should survive the filter")
    }

    @Test("playlistVideoRenderer reel endpoint stays a Short regardless of duration")
    func playlistVideoRendererReelEndpointLongDuration_isShortTrue() async throws {
        let json: [String: Any] = [
            "items": [
                playlistVideoRendererJSON(videoId: "LONG_PV_1", extras: [
                    "navigationEndpoint": ["reelWatchEndpoint": ["videoId": "LONG_PV_1"]],
                    "lengthText": ["simpleText": "3:01"]
                ])
            ]
        ]
        let api = InnerTubeAPI()
        let group = try await api.parseVideoGroupForTesting(json, title: nil)
        #expect(group.videos.count == 1)
        #expect(group.videos.first?.isShort == true, "Explicit reelWatchEndpoint is authoritative; duration is not a classifier")
    }
}
