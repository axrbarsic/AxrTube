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

    @Test("Global mini player is hidden only on Downloads")
    func miniPlayerVisibility() {
        #expect(iPocketTubeInformationArchitecture.showsGlobalMiniPlayer(on: .search))
        #expect(iPocketTubeInformationArchitecture.showsGlobalMiniPlayer(on: .media))
        #expect(!iPocketTubeInformationArchitecture.showsGlobalMiniPlayer(on: .downloads))
        #expect(iPocketTubeInformationArchitecture.showsGlobalMiniPlayer(on: .settings))
    }

    @Test("Empty search uses data-backed surfaces, not English defaults")
    func noHardcodedEnglishSuggestions() async {
        let model = SearchViewModel()
        await model.updateSuggestions(for: "")
        #expect(model.suggestions.isEmpty)
    }
}
