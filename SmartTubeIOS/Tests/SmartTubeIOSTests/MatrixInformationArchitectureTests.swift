import Testing
@testable import SmartTubeIOSCore

@Suite("AxrTube Matrix information architecture")
@MainActor
struct MatrixInformationArchitectureTests {
    @Test("Exactly four primary routes have one stable order")
    func primaryRouteMap() {
        #expect(AxrTubeInformationArchitecture.primaryRoutes == [
            .search, .media, .downloads, .settings,
        ])
    }

    @Test("Downloads owns collection and storage controls")
    func uniqueFeatureOwnership() {
        #expect(AxrTubeInformationArchitecture.downloadsOwner == .downloads)
        #expect(AxrTubeInformationArchitecture.storageOwner == .downloads)
    }

    @Test("Global mini player is hidden only on Downloads")
    func miniPlayerVisibility() {
        #expect(AxrTubeInformationArchitecture.showsGlobalMiniPlayer(on: .search))
        #expect(AxrTubeInformationArchitecture.showsGlobalMiniPlayer(on: .media))
        #expect(!AxrTubeInformationArchitecture.showsGlobalMiniPlayer(on: .downloads))
        #expect(AxrTubeInformationArchitecture.showsGlobalMiniPlayer(on: .settings))
    }

    @Test("Empty search uses data-backed surfaces, not English defaults")
    func noHardcodedEnglishSuggestions() async {
        let model = SearchViewModel()
        await model.updateSuggestions(for: "")
        #expect(model.suggestions.isEmpty)
    }
}
