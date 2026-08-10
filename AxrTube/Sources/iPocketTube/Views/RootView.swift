import SwiftUI
import iPocketTubeCore
import OSLog
#if os(iOS)
@preconcurrency import Translation
#endif

private let rootLog = Logger(subsystem: "com.void.ipockettube.app", category: "RootView")

// MARK: - RootView
//
// Entry point that decides whether to show the main tab UI or the
// sign-in screen.  On macOS it uses a sidebar-based navigation.

public struct RootView: View {
    @Environment(AuthService.self) private var auth
    @Environment(SettingsStore.self) private var store
    @Environment(BrowseViewModel.self) private var browseVM
    @Environment(\.innerTubeAPI) private var api
    /// Shared download service — observed here so the completion alert is shown
    /// at a stable level unaffected by context menu dismiss animations on cards.
    @Environment(VideoDownloadService.self) private var cardDownloadService
    @State private var cardDownloadAlertItem: DownloadAlertItem?

    public init() {}

    public var body: some View {
        // Explicitly read cardDownloadService.state in body so SwiftUI's
        // @Observable tracking engine registers this view as a subscriber.
        // Without this, onChange(of: cardDownloadService.state) may not fire
        // when the state changes on an environment-injected @Observable object.
        let _ = cardDownloadService.state
        Group {
            #if os(tvOS)
            MainTVTabView()
            #elseif os(macOS)
            MainSidebarView()
            #else
            MainTabView()
            #endif
        }
        .iPocketTubeScreenSurface()
        .preferredColorScheme(store.settings.themeName.colorScheme)
        #if !os(tvOS)
        .onChange(of: cardDownloadService.state) { _, newState in
            switch newState {
            case .done:
                if cardDownloadService.lastWasAutomatic {
                    cardDownloadService.reset()
                    return
                }
                let isAudio = cardDownloadService.lastCompletedKind == .audio
                cardDownloadAlertItem = DownloadAlertItem(
                    title: String(localized: isAudio ? "Audio Saved" : "Video Saved", bundle: .module),
                    message: cardDownloadService.lastSavedToPhotos
                        ? String(localized: "The video is in Photos and AxrTube's offline collection.", bundle: .module)
                        : String(localized: "The item is available in AxrTube's offline collection.", bundle: .module)
                )
                iPocketTubeHaptics.shared.perform(.operationSucceeded)
                cardDownloadService.reset()
            case .failed(let reason):
                if cardDownloadService.lastWasAutomatic {
                    cardDownloadService.reset()
                    return
                }
                cardDownloadAlertItem = DownloadAlertItem(
                    title: String(localized: "Download Failed", bundle: .module),
                    message: reason
                )
                iPocketTubeHaptics.shared.perform(.operationFailed)
                cardDownloadService.reset()
            default:
                break
            }
        }
        .alert(
            cardDownloadAlertItem?.title ?? "",
            isPresented: Binding(
                get: { cardDownloadAlertItem != nil },
                set: { if !$0 { cardDownloadAlertItem = nil } }
            ),
            presenting: cardDownloadAlertItem
        ) { _ in
            Button("OK") {
                iPocketTubeHaptics.shared.perform(.primaryAction)
                cardDownloadAlertItem = nil
            }
        } message: { item in
            Text(item.message)
        }
        #endif
        #if os(iOS)
        // Deep link is handled by MainTabView.onChange(of: browseVM.deepLinkedVideo)
        // which calls playerRouter.open(video:api:). No landscapePlayerCover needed here.
        #endif
    }
}

// MARK: - AppSection

enum AppSection: String, CaseIterable, Identifiable {
    case home      = "Home"
    case search    = "Search"
    case library   = "Library"
    case downloads = "Downloads"
    case settings  = "Settings"

    static var allCases: [AppSection] {
        #if os(iOS)
        [.search, .library, .downloads, .settings]
        #else
        [.home, .search, .library, .settings]
        #endif
    }

    var id: String { rawValue }

    var localizedTitle: String {
        switch self {
        case .home:     return String(localized: "Home", bundle: .module)
        case .search:   return String(localized: "Search", bundle: .module)
        case .library:  return String(localized: "Media Library", bundle: .module)
        case .downloads:return String(localized: "Downloads", bundle: .module)
        case .settings: return String(localized: "Settings", bundle: .module)
        }
    }

    #if os(iOS)
    var primaryRoute: iPocketTubePrimaryRoute? {
        switch self {
        case .search: .search
        case .library: .media
        case .downloads: .downloads
        case .settings: .settings
        case .home: nil
        }
    }
    #endif

    var icon: String {
        switch self {
        case .home:     return AppSymbol.home
        case .search:   return AppSymbol.search
        case .library:  return AppSymbol.library
        case .downloads:return AppSymbol.download
        case .settings: return AppSymbol.settings
        }
    }

    @MainActor @ViewBuilder
    func destination(api: InnerTubeAPI) -> some View {
        switch self {
        case .home:     HomeView(api: api)
        case .search:   SearchView()
        case .library:  LibraryView()
        case .downloads:DownloadsView()
        case .settings: SettingsView()
        }
    }
}

// MARK: - MainTabView  (iOS / iPadOS)

struct MainTabView: View {
    @State private var searchVM = SearchViewModel()
    @State private var selectedTab: AppSection = .search
    @Environment(\.innerTubeAPI) private var api
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    #if os(iOS)
    @Environment(PlayerStateStore.self) private var playerState
    @Environment(TOSPlayerStateStore.self) private var tosState
    @Environment(PlayerRouter.self) private var playerRouter
    @Environment(BrowseViewModel.self) private var browseVM
    @State private var showSrcSwapSpike = false
    #endif

    var body: some View {
        #if os(iOS)
        // Read these in body so SwiftUI's @Observable tracker registers the dependency.
        // If only accessed inside the Binding.get closure, changes won't trigger a body re-render
        // and updateUIViewController won't be called, so the cover never dismisses.
        let fullScreenVideo: Video? = playerState.presentation == .fullScreen ? playerState.currentVideo : nil
        let _ = rootLog.notice("[MainTabView] body re-render — presentation=\(String(describing: playerState.presentation)) fullScreenVideo=\(fullScreenVideo?.id ?? "nil")")
        let fullScreenBinding = Binding<Video?>(
            get: { fullScreenVideo },
            set: { newValue in
                // Only transition to mini player when the cover is dismissed while
                // presentation is still .fullScreen. If stop() already moved us to
                // .hidden, the async onDismiss callback must not resurrect the mini
                // player by calling minimize() — that is the race condition that
                // caused the mini-player X button to unexpectedly restore fullscreen.
                guard newValue == nil, playerState.presentation == .fullScreen else { return }
                playerState.minimize()
            }
        )
        // TOS full-screen cover binding — mirrors the AVPlayer binding above.
        // When the user swipes down or the system dismisses the cover while TOS is
        // still in .fullScreen, this setter calls minimize() so audio continues in
        // TOSMiniPlayerView. If tosState.stop() already moved us to .hidden the
        // setter is a no-op (guard prevents spurious minimize).
        let tosFullScreenVideo: Video? = tosState.presentation == .fullScreen ? tosState.currentVideo : nil
        let tosFullScreenBinding = Binding<Video?>(
            get: { tosFullScreenVideo },
            set: { newValue in
                guard newValue == nil, tosState.presentation == .fullScreen else { return }
                tosState.minimize()
            }
        )
        #endif
        TabView(selection: Binding(
            get: { selectedTab },
            set: { newValue in
                guard newValue != selectedTab else { return }
                iPocketTubeHaptics.shared.perform(.tabSelection)
                selectedTab = newValue
            }
        )) {
            ForEach(AppSection.allCases) { section in
                NavigationStack { section.destination(api: api) }
                    #if os(iOS)
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        if #unavailable(iOS 26.0),
                           section == selectedTab,
                           showsCompactNowPlayingAccessory {
                            globalMiniPlayer
                        }
                    }
                    #endif
                    .tabItem { Label(section.localizedTitle, systemImage: section.icon) }
                    .tag(section)
                    .accessibilityIdentifier("tab.\(section.rawValue.lowercased())")
            }
        }
        #if os(iOS)
        .iPocketTubeLiquidTabChrome(isAccessoryPresented: showsCompactNowPlayingAccessory) {
            globalMiniPlayer
        }
        #endif
        .environment(searchVM)
        .onReceive(NotificationCenter.default.publisher(for: .navigateToSearch)) { _ in
            if selectedTab != .search {
                iPocketTubeHaptics.shared.perform(.tabSelection)
            }
            selectedTab = .search
        }
        #if os(iOS)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: showsCompactNowPlayingAccessory)
        .translationTask(playerState.vm.russianTranscriptTranslation.configuration) { session in
            await playerState.vm.russianTranscriptTranslation.prepareTranslation(using: session)
        }
        .landscapePlayerCover(item: fullScreenBinding, dismissStore: playerState) { video in
            PlayerView(video: video, api: api)
        }
        // TOS player full-screen cover — presented when tosState.presentation == .fullScreen.
        // TOSPlayerView reads tosState from the environment (injected via AppEntry) so the
        // WKWebView that was created by TOSPlayerStateStore.play(video:api:) is reused here.
        .landscapePlayerCover(item: tosFullScreenBinding, dismissStore: tosState) { video in
            TOSPlayerView(video: video, api: api) {
                // Fatal IFrame error (embedding disabled / not found) — mark this
                // video so PlayerRouter routes it to AVPlayer (and any future taps
                // on the same video), then re-open it through the router.
                tosState.markFallback(videoId: video.id)
                playerRouter.open(video: video, api: api)
            }
        }
        .onChange(of: browseVM.deepLinkedVideo) { _, video in
            guard let video else { return }
            playerRouter.open(video: video, api: api)
            browseVM.deepLinkedVideo = nil
        }
        // UI-testing only: invisible button that re-opens the deeplink video in the
        // same session after stop() so testSecondOpenAfterStopPlays can verify the fix.
        // Uses the same browseVM.deepLinkedVideo path as the production deeplink, so
        // the full playerRouter.open() code path is exercised.
        .overlay(alignment: .bottomLeading) {
            let isUITesting = ProcessInfo.processInfo.arguments.contains("--uitesting")
            let deeplinkArg = ProcessInfo.processInfo.arguments
                .first(where: { $0.hasPrefix("--uitesting-deeplink-video=") })
            let deeplinkID: String? = deeplinkArg.map {
                let id = String($0.dropFirst("--uitesting-deeplink-video=".count))
                return id.isEmpty ? nil : id
            } ?? nil
            if isUITesting, let id = deeplinkID,
               playerState.presentation == .hidden, tosState.presentation == .hidden {
                Button {
                    browseVM.deepLinkedVideo = Video(id: id, title: "", channelTitle: "")
                } label: {
                    Color.clear.frame(width: 44, height: 44)
                }
                .accessibilityIdentifier("uitesting.reopenDeeplinkVideoButton")
            }
        }
        .fullScreenCover(isPresented: $showSrcSwapSpike) {
            ShortsEmbedSrcSwapSpikeView()
        }
        .onAppear {
            if ProcessInfo.processInfo.arguments.contains("--uitesting-shorts-srcswap-spike") {
                showSrcSwapSpike = true
            }
        }
        #endif
    }

    #if os(iOS)
    private var showsCompactNowPlayingAccessory: Bool {
        guard let route = selectedTab.primaryRoute else { return false }
        let hasRecoverableItem = playerState.presentation == .miniPlayer || tosState.presentation == .miniPlayer
        return iPocketTubeInformationArchitecture.showsGlobalMiniPlayer(
            on: route,
            hasRecoverableItem: hasRecoverableItem
        )
    }

    @ViewBuilder private var globalMiniPlayer: some View {
        if showsCompactNowPlayingAccessory, playerState.presentation == .miniPlayer {
            MiniPlayerView {
                iPocketTubeHaptics.shared.perform(.contentSelection)
                selectedTab = .downloads
            }
                .transition(.opacity)
        } else if showsCompactNowPlayingAccessory, tosState.presentation == .miniPlayer {
            TOSMiniPlayerView()
                .transition(.opacity)
        }
    }
    #endif
}

// MARK: - MainTVTabView  (tvOS)
// Top-bar TabView is the Apple-recommended navigation pattern for Apple TV.
// Each tab contains a NavigationStack so drill-down is available within each section.

#if os(tvOS)
struct MainTVTabView: View {
    @State private var searchVM = SearchViewModel()
    @State private var selectedTab: AppSection = .home
    @Environment(\.innerTubeAPI) private var api

    var body: some View {
        TabView(selection: $selectedTab) {
            ForEach(AppSection.allCases) { section in
                NavigationStack { section.destination(api: api) }
                    .tabItem {
                        Label(section.localizedTitle, systemImage: section.icon)
                    }
                    .tag(section)
            }
        }
        .environment(searchVM)
    }
}
#endif

// MARK: - MainSidebarView  (macOS)

struct MainSidebarView: View {
    @Environment(AuthService.self) private var auth
    @Environment(BrowseViewModel.self) private var browseVM
    @Environment(SettingsStore.self) private var store
    @Environment(\.innerTubeAPI) private var api
    @State private var searchVM = SearchViewModel()

    @State private var selectedSection: AppSection? = .home
    /// Set when the IFrame player hits a fatal embed error on the current video so we
    /// drop through to the standard PlayerView for that video only. Cleared when the
    /// video changes.
    @State private var tosPlayerFallbackVideoId: String? = nil

    var body: some View {
        @Bindable var browseVM = browseVM
        ZStack {
            NavigationSplitView {
                List(AppSection.allCases, selection: $selectedSection) { section in
                    Label(section.localizedTitle, systemImage: section.icon)
                        .tag(section)
                }
                .navigationTitle("AxrTube")
                if auth.isSignedIn {
                    Divider()
                    HStack {
                        AsyncImage(url: auth.accountAvatarURL) { img in img.resizable() } placeholder: { Color.gray }
                            .frame(width: 28, height: 28)
                            .clipShape(Circle())
                        Text(auth.accountName ?? "Account")
                            .font(.subheadline)
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 8)
                }
            } detail: {
                NavigationStack { (selectedSection ?? .home).destination(api: api) }
            }
            .environment(searchVM)

            // Full-window player overlay — avoids macOS sheet coordinate issues that
            // prevent XCUITest click events from reaching controls inside a popover window.
            if let video = browseVM.deepLinkedVideo {
#if os(macOS)
                let shouldUseTOS = store.settings.useTOSPlayerOnMac
                                   && tosPlayerFallbackVideoId != video.id
                if shouldUseTOS {
                    // TOS-compliant IFrame player experiment (macOS only, opt-in).
                    // Falls back to the standard PlayerView on embedding-disabled videos.
                    TOSPlayerView(video: video, api: api) {
                        // Mark this video ID so the guard above drops to PlayerView.
                        tosPlayerFallbackVideoId = video.id
                    }
                    .environment(store)
                    .environment(auth)
                    .environment(browseVM)
                    .ignoresSafeArea()
                } else {
                    PlayerView(video: video, api: api)
                        .environment(store)
                        .environment(auth)
                        .environment(browseVM)
                        .ignoresSafeArea()
                }
#else
                PlayerView(video: video, api: api)
                    .environment(store)
                    .environment(auth)
                    .environment(browseVM)
                    .ignoresSafeArea()
#endif
            }
        }
        // When a different video is opened, clear the per-video fallback guard so
        // the next video gets a fresh attempt through the TOS player.
        .onChange(of: browseVM.deepLinkedVideo?.id) { _, newId in
            if newId != tosPlayerFallbackVideoId {
                tosPlayerFallbackVideoId = nil
            }
        }
    }
}
