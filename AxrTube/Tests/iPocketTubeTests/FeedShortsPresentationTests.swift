import Foundation
import Testing
@testable import iPocketTubeCore

@Suite("iPocketTube feed Shorts presentation")
struct FeedShortsPresentationTests {
    private func video(_ id: String, duration: TimeInterval, isShort: Bool) -> Video {
        Video(id: id, title: id, channelTitle: "Channel", duration: duration, isShort: isShort)
    }

    @Test("Show Shorts is off by default and persists both values")
    func settingDefaultAndRoundTrip() throws {
        var settings = AppSettings()
        #expect(!settings.showShorts)

        settings.showShorts = true
        let enabled = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(enabled.showShorts)

        settings.showShorts = false
        let disabled = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(!disabled.showShorts)
    }

    @Test("Filtering uses explicit isShort metadata, never duration")
    func filterHasNoDurationFalsePositive() {
        let ordinaryTwentySecondVideo = video("ordinary", duration: 20, isShort: false)
        let explicitlyMarkedLongShort = video("short", duration: 240, isShort: true)

        let hidden = FeedCatalogPolicy.visibleVideos(
            [ordinaryTwentySecondVideo, explicitlyMarkedLongShort],
            showShorts: false
        )
        #expect(hidden.map(\.id) == ["ordinary"])

        let shown = FeedCatalogPolicy.visibleVideos(
            [ordinaryTwentySecondVideo, explicitlyMarkedLongShort],
            showShorts: true
        )
        #expect(shown.map(\.id) == ["ordinary", "short"])
    }

    @Test("iPhone catalog is exactly one column")
    func singleColumnContract() {
        #expect(FeedCatalogPolicy.iOSColumnCount == 1)
    }

    @Test("Visible catalogue compacts invalid and duplicate identities without empty slots")
    func visibleCatalogueHasStableUniqueIDs() {
        let first = video("stable", duration: 60, isShort: false)
        var richerDuplicate = video("stable", duration: 60, isShort: false)
        richerDuplicate.publishedTimeText = "сегодня"
        let invalid = video("", duration: 60, isShort: false)
        let other = video("other", duration: 60, isShort: false)

        let visible = FeedCatalogPolicy.visibleVideos(
            [first, invalid, richerDuplicate, other],
            showShorts: true
        )

        #expect(visible.map(\.id) == ["stable", "other"])
        #expect(visible.first?.publishedTimeText == "сегодня")
        #expect(Set(visible.map(\.id)).count == visible.count)
    }

    @Test("Search and media compact toggles select independent shared card variants")
    func independentCompactCardPolicy() {
        #expect(VideoCardLayoutPolicy.variant(
            for: .search,
            compactSearchCards: true,
            compactMediaLibraryCards: false
        ) == .compact)
        #expect(VideoCardLayoutPolicy.variant(
            for: .mediaLibrary,
            compactSearchCards: true,
            compactMediaLibraryCards: false
        ) == .regular)
        #expect(VideoCardLayoutPolicy.variant(
            for: .standard,
            compactSearchCards: true,
            compactMediaLibraryCards: true
        ) == .regular)
    }

    @Test("Every Media Library video route follows the same toggle in both directions")
    func mediaLibraryRouteParity() {
        #expect(Set(MediaLibraryVideoRoute.allCases.map(\.rawValue)) == Set([
            "subscriptions", "history", "playlists", "playlistContents", "rssFeed", "channelUploads",
        ]))

        for route in MediaLibraryVideoRoute.allCases {
            #expect(route.catalogContext == .mediaLibrary)
            #expect(VideoCardLayoutPolicy.variant(
                for: route.catalogContext,
                compactSearchCards: false,
                compactMediaLibraryCards: true
            ) == .compact)
            #expect(VideoCardLayoutPolicy.variant(
                for: route.catalogContext,
                compactSearchCards: true,
                compactMediaLibraryCards: false
            ) == .regular)
        }
    }

    @Test("Search toggle cannot change Media and Media toggle cannot change Search")
    func searchAndMediaRemainIndependentInBothDirections() {
        for searchEnabled in [false, true] {
            #expect(VideoCardLayoutPolicy.variant(
                for: .mediaLibrary,
                compactSearchCards: searchEnabled,
                compactMediaLibraryCards: false
            ) == .regular)
        }
        for mediaEnabled in [false, true] {
            #expect(VideoCardLayoutPolicy.variant(
                for: .search,
                compactSearchCards: false,
                compactMediaLibraryCards: mediaEnabled
            ) == .regular)
        }
    }
}
