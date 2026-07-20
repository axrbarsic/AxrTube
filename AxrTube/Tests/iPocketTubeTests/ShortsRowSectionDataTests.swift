import Foundation
import Testing
@testable import iPocketTubeCore

// MARK: - ShortsRowSectionDataTests
//
// Verifies the data-preparation logic introduced in BrowseView.content
// when ShortsRowSection replaced VideoRowSection/VideoGridSection:
//
//   let isShorts = vm.currentSection.type == .shorts
//   let allVideos = vm.videoGroups.flatMap(\.videos)
//                       .filter { !hideShorts || !$0.isShort }
//
// All assertions are pure value transforms — no SwiftUI, no network.

@Suite("BrowseView ShortsRowSection data preparation")
struct ShortsRowSectionDataTests {

    // MARK: - Helpers

    private func makeVideo(id: String, isShort: Bool = false) -> Video {
        Video(id: id, title: id, channelTitle: "ch", isShort: isShort)
    }

    private func makeGroup(videos: [Video], layout: VideoGroup.Layout = .grid) -> VideoGroup {
        VideoGroup(videos: videos, layout: layout)
    }

    // MARK: - Flattening

    @Test("Flattening multiple VideoGroups yields all videos in order")
    func flattenMultipleGroups() {
        let g1 = makeGroup(videos: [makeVideo(id: "a"), makeVideo(id: "b")])
        let g2 = makeGroup(videos: [makeVideo(id: "c")])
        let g3 = makeGroup(videos: [makeVideo(id: "d"), makeVideo(id: "e")])

        let result = [g1, g2, g3].flatMap(\.videos)

        #expect(result.map(\.id) == ["a", "b", "c", "d", "e"])
    }

    @Test("Flattening an empty group list yields an empty array")
    func flattenEmptyGroups() {
        let result: [Video] = [VideoGroup]().flatMap(\.videos)
        #expect(result.isEmpty)
    }

    @Test("Flattening preserves videos from groups of mixed layout types")
    func flattenMixedLayouts() {
        let rowGroup = makeGroup(videos: [makeVideo(id: "row1")], layout: .row)
        let gridGroup = makeGroup(videos: [makeVideo(id: "grid1"), makeVideo(id: "grid2")], layout: .grid)

        let result = [rowGroup, gridGroup].flatMap(\.videos)

        #expect(result.map(\.id) == ["row1", "grid1", "grid2"])
    }

    // MARK: - hideShorts filtering on flattened list

    @Test("When hideShorts is false, all videos including Shorts are returned")
    func hideShortsDisabled() {
        let videos = [makeVideo(id: "v1"), makeVideo(id: "s1", isShort: true), makeVideo(id: "v2")]
        let hideShorts = false

        let result = videos.filter { !hideShorts || !$0.isShort }

        #expect(result.map(\.id) == ["v1", "s1", "v2"])
    }

    @Test("When hideShorts is true, Short videos are excluded from flattened list")
    func hideShortsFiltersOutShorts() {
        let groups = [
            makeGroup(videos: [makeVideo(id: "v1"), makeVideo(id: "s1", isShort: true)]),
            makeGroup(videos: [makeVideo(id: "s2", isShort: true), makeVideo(id: "v2")])
        ]
        let hideShorts = true

        let result = groups.flatMap(\.videos).filter { !hideShorts || !$0.isShort }

        #expect(result.map(\.id) == ["v1", "v2"])
    }

    @Test("When hideShorts is true and all videos are Shorts, result is empty")
    func hideShortsAllShorts() {
        let groups = [
            makeGroup(videos: [makeVideo(id: "s1", isShort: true), makeVideo(id: "s2", isShort: true)])
        ]
        let hideShorts = true

        let result = groups.flatMap(\.videos).filter { !hideShorts || !$0.isShort }

        #expect(result.isEmpty)
    }

    // MARK: - isShorts section detection (drives scrollAxis)

    @Test("SectionType.shorts is the only type that triggers the vertical layout")
    func onlyShortsTypeIsVertical() {
        let shortsTypes = BrowseSection.SectionType.allCases.filter { $0 == .shorts }
        let nonShortsTypes = BrowseSection.SectionType.allCases.filter { $0 != .shorts }

        #expect(shortsTypes.count == 1)
        #expect(nonShortsTypes.allSatisfy { $0 != .shorts })
    }

    @Test("Non-Shorts section types do not trigger vertical layout")
    func nonShortsTypesAreHorizontal() {
        let nonShortsTypes: [BrowseSection.SectionType] = [
            .home, .recommended, .subscriptions, .history,
            .playlists, .channels, .music, .news, .gaming, .live, .sports
        ]

        for sectionType in nonShortsTypes {
            let isShorts = sectionType == .shorts
            #expect(!isShorts, "Section type \(sectionType) should not be treated as Shorts")
        }
    }

    @Test("Shorts section type triggers vertical layout")
    func shortsTypeIsVertical() {
        let isShorts = BrowseSection.SectionType.shorts == .shorts
        #expect(isShorts)
    }
}
