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

    @Test("One compact setting controls Search, Media Library, and Downloads")
    func unifiedCompactCardPolicy() {
        for context in [
            VideoCardCatalogContext.search,
            .mediaLibrary,
            .downloads,
        ] {
            #expect(VideoCardLayoutPolicy.variant(
                for: context,
                compactCards: true
            ) == .compact)
            #expect(VideoCardLayoutPolicy.variant(
                for: context,
                compactCards: false
            ) == .regular)
        }
        #expect(VideoCardLayoutPolicy.variant(
            for: .standard,
            compactCards: true
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
                compactCards: true
            ) == .compact)
            #expect(VideoCardLayoutPolicy.variant(
                for: route.catalogContext,
                compactCards: false
            ) == .regular)
        }
    }

    @Test("Active Downloads Now Playing card is always regular")
    func activeDownloadCardException() {
        #expect(VideoCardLayoutPolicy.variant(
            for: .downloads,
            compactCards: true,
            isActiveNowPlaying: false
        ) == .compact)
        for compactCards in [false, true] {
            #expect(VideoCardLayoutPolicy.variant(
                for: .downloads,
                compactCards: compactCards,
                isActiveNowPlaying: true
            ) == .regular)
        }
    }

    @Test("Compact setting persists after settings recreation")
    func compactSettingRoundTrip() throws {
        var settings = AppSettings()
        settings.compactSearchCards = false
        let regular = try JSONDecoder().decode(
            AppSettings.self,
            from: JSONEncoder().encode(settings)
        )
        #expect(!regular.compactSearchCards)

        settings.compactSearchCards = true
        let compact = try JSONDecoder().decode(
            AppSettings.self,
            from: JSONEncoder().encode(settings)
        )
        #expect(compact.compactSearchCards)
    }

    @Test("Compact download rows preserve progress, error, and retry controls")
    func compactDownloadStatusControls() {
        #expect(DownloadCardPresentationPolicy.statusPresentation(
            status: .downloading,
            resumePolicy: .automatic,
            failureReason: nil
        ) == .progressAndCancel)
        #expect(DownloadCardPresentationPolicy.statusPresentation(
            status: .failed,
            resumePolicy: .automatic,
            failureReason: .transientNetwork
        ) == .failure(showsRetry: true))
        #expect(DownloadCardPresentationPolicy.statusPresentation(
            status: .failed,
            resumePolicy: .automatic,
            failureReason: .regionRestricted
        ) == .failure(showsRetry: false))
        #expect(DownloadCardPresentationPolicy.statusPresentation(
            status: .paused,
            resumePolicy: .manual,
            failureReason: nil
        ) == .paused(showsContinue: true))
        #expect(DownloadCardPresentationPolicy.statusPresentation(
            status: .finalizationPending,
            resumePolicy: .automatic,
            failureReason: nil
        ) == .finalizationRetry)
    }
}
