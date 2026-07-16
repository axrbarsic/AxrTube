import SwiftUI
import SmartTubeIOSCore

/// App entry point – supports iOS 17+, iPadOS 17+, macOS 14+.
struct SmartTubeApp: App {
    @State private var api: InnerTubeAPI
    @State private var authService: AuthService
    @State private var browseViewModel: BrowseViewModel
    @State private var settingsStore: SettingsStore
    /// App-scoped download coordinator shared by cards, player, and collection.
    @State private var cardDownloadService: VideoDownloadService
    @Environment(\.scenePhase) private var scenePhase

    init() {
        #if DEBUG && os(iOS)
        AudioRecoverySimulatorProbe.runIfRequested()
        #endif
        let api = InnerTubeAPI()
        _api = State(initialValue: api)
        _authService = State(initialValue: AuthService())
        _browseViewModel = State(initialValue: BrowseViewModel(api: api))
        _settingsStore = State(initialValue: SettingsStore())
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
                .environment(DownloadStore.shared)
                .onChange(of: authService.accessToken, initial: true) { _, newToken in
                    Task {
                        await api.setAuthToken(newToken)
                        await browseViewModel.updateAuthToken(newToken)
                    }
                }
                .onChange(of: settingsStore.settings.enabledSections) { _, newSections in
                    browseViewModel.configureSections(newSections)
                }
                .task {
                    // Sync enablement state on launch, then start the iCloud KV listener.
                    iCloudSyncManager.shared.syncEnabled = settingsStore.settings.iCloudSyncEnabled
                    await iCloudSyncManager.shared.start()
                }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task {
                    await authService.refreshIfNeeded()
                    authService.handleForeground()
                }
            }
        }
        #if os(macOS)
        .defaultSize(width: 1280, height: 800)
        #endif
    }
}
