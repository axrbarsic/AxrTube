import Testing
@testable import iPocketTubeCore

@Suite("iPocketTube Matrix information architecture")
@MainActor
struct MatrixInformationArchitectureTests {
    @Test("Exactly four primary routes have one stable order")
    func primaryRouteMap() {
        #expect(iPocketTubeInformationArchitecture.primaryRoutes == [
            .search, .media, .downloads, .settings,
        ])
    }

    @Test("Downloads owns collection and storage controls")
    func uniqueFeatureOwnership() {
        #expect(iPocketTubeInformationArchitecture.downloadsOwner == .downloads)
        #expect(iPocketTubeInformationArchitecture.storageOwner == .downloads)
    }

    @Test("One Now Playing surface is selected for every primary route")
    func miniPlayerVisibility() {
        for route in iPocketTubePrimaryRoute.allCases {
            #expect(iPocketTubeInformationArchitecture.nowPlayingSurface(
                on: route,
                hasRecoverableItem: false
            ) == .hidden)
        }

        #expect(iPocketTubeInformationArchitecture.nowPlayingSurface(
            on: .search,
            hasRecoverableItem: true
        ) == .compactAccessory)
        #expect(iPocketTubeInformationArchitecture.nowPlayingSurface(
            on: .media,
            hasRecoverableItem: true
        ) == .compactAccessory)
        #expect(iPocketTubeInformationArchitecture.nowPlayingSurface(
            on: .downloads,
            hasRecoverableItem: true
        ) == .expandedDownloadsCard)
        #expect(iPocketTubeInformationArchitecture.nowPlayingSurface(
            on: .settings,
            hasRecoverableItem: true
        ) == .compactAccessory)
    }

    @Test("Empty search uses data-backed surfaces, not English defaults")
    func noHardcodedEnglishSuggestions() async {
        let model = SearchViewModel()
        await model.updateSuggestions(for: "")
        #expect(model.suggestions.isEmpty)
    }
}
