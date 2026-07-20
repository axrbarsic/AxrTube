import SwiftUI
import iPocketTube
import iPocketTubeCore

/// tvOS entry point for iPocketTube.
/// The device-code + QR sign-in flow is natively designed for Apple TV —
/// the user reads a code on screen and activates on their phone at yt.be/activate.
@main
struct iPocketTubeTVApp: App {
    @State private var api: InnerTubeAPI
    @State private var authService: AuthService
    @State private var browseViewModel: BrowseViewModel
    @State private var settingsStore: SettingsStore
    /// Shared download service — required by RootView and VideoCardView even on
    /// tvOS (where downloads are disabled in UI). Must be present in the environment
    /// or SwiftUI throws a fatal "No Observable object of type VideoDownloadService"
    /// error at launch.
    @State private var cardDownloadService: VideoDownloadService

    init() {
        let settingsStore = SettingsStore()
        let poTokenProvider: (any PoTokenProvider)? = {
            if let url = settingsStore.settings.poTokenServiceURL {
                return ServerPoTokenProvider(serviceURL: url)
            }
            return BotGuardClient()
        }()
        let api = InnerTubeAPI(authToken: nil, poTokenProvider: poTokenProvider)
        _api                 = State(initialValue: api)
        _authService         = State(initialValue: AuthService())
        _browseViewModel     = State(initialValue: BrowseViewModel(api: api))
        _settingsStore       = State(initialValue: settingsStore)
        _cardDownloadService = State(initialValue: VideoDownloadService(api: api))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(authService)
                .environment(browseViewModel)
                .environment(settingsStore)
                .environment(\.innerTubeAPI, api)
                .environment(cardDownloadService)
                .task(id: authService.authSnapshot) {
                    let snapshot = authService.authSnapshot
                    await api.applyAuthSnapshot(snapshot)
                    await browseViewModel.applyAuthSnapshot(snapshot)
                }
                .onChange(of: settingsStore.settings.enabledSections) { _, newSections in
                    browseViewModel.configureSections(newSections)
                }
                .onChange(of: settingsStore.settings.historyState, initial: true) { _, newState in
                    browseViewModel.updateHistoryEnabled(newState == .enabled)
                }
        }
    }
}
