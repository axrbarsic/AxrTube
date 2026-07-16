import SwiftUI
import iPocketTubeCore

// MARK: - LibraryView
//
// Shows subscriptions, playlists, watch history and liked videos for the
// signed-in account.  Mirrors the Android launcher activities for
// Subscriptions, Playlists, History and Channels.

public struct LibraryView: View {
    @Environment(AuthService.self) private var auth
    @Environment(BrowseViewModel.self) private var browseVM
    @Environment(\.innerTubeAPI) private var api
    @Environment(SettingsStore.self) private var store
    @State private var selectedSection: LibrarySection = .subscriptions
    @State private var selectedVideo: Video?
    @State private var selectedPlaylist: Video?
    @State private var channelDestination: ChannelDestination?
    @State private var scrollStore = ScrollOffsetStore()
    @State private var savedScrollOffset: CGFloat? = nil
    @State private var restoreOffset: CGFloat? = nil
    @State private var queueVideosCount: Int = 0
    #if os(iOS)
    @Environment(PlayerRouter.self) private var playerRouter
    #endif
    #if os(tvOS)
    @FocusState private var focusedSection: LibrarySection?
    #endif

    enum LibrarySection: String, CaseIterable, Identifiable {
        case subscriptions = "Subs"
        case history       = "History"
        case playlists     = "Playlists"
        case channels      = "Channels"

        var id: String { rawValue }
        var localizedTitle: String {
            switch self {
            case .subscriptions: return String(localized: "Subs", bundle: .module)
            case .history:       return String(localized: "History", bundle: .module)
            case .playlists:     return String(localized: "Playlists", bundle: .module)
            case .channels:      return String(localized: "Channels", bundle: .module)
            }
        }
        var browseSectionType: BrowseSection.SectionType {
            switch self {
            case .subscriptions: return .subscriptions
            case .history:       return .history
            case .playlists:     return .playlists
            case .channels:      return .channels
            }
        }
    }

    public init() {}

    public var body: some View {
        Group {
            libraryContent
        }
        .iPocketTubeScreenSurface()
        #if os(iOS) || os(tvOS)
        .toolbar(.hidden, for: .navigationBar)
        #endif
        #if !os(iOS)
        .navigationDestination(item: $selectedVideo) { video in
            PlayerView(video: video, api: api)
        }
        #endif
        .navigationDestination(item: $selectedPlaylist) { stub in
            PlaylistView(playlistId: stub.id, playlistTitle: stub.title, api: api, catalogContext: .mediaLibrary)
        }
        .navigationDestination(item: $channelDestination) { dest in
            ChannelView(channelId: dest.channelId, catalogContext: .mediaLibrary)
        }
        .onReceive(NotificationCenter.default.publisher(for: .openChannel)) { note in
            guard let channelId = note.userInfo?["channelId"] as? String, !channelId.isEmpty else { return }
            channelDestination = ChannelDestination(channelId: channelId)
        }
    }

    private var libraryContent: some View {
        VStack(spacing: 0) {
            iPocketTubeMatrixHeader(title: "Media Library")
            #if os(tvOS)
            HStack(spacing: 8) {
                ForEach(LibrarySection.allCases) { sec in
                    let isSelected = selectedSection == sec
                    Button {
                        guard selectedSection != sec else { return }
                        iPocketTubeHaptics.shared.perform(.segmentSelection)
                        selectedSection = sec
                    } label: {
                        Text(verbatim: sec.localizedTitle)
                            .font(.headline)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 12)
                            .background(
                                (isSelected || focusedSection == sec) ? Color.primary : Color.secondary.opacity(0.15),
                                in: Capsule()
                            )
                            .foregroundStyle(
                                (isSelected || focusedSection == sec) ? Color(white: 0) : Color.primary
                            )
                    }
                    .buttonStyle(.borderless)
                    .scaleEffect(focusedSection == sec ? 1.12 : 1.0)
                    .animation(.easeInOut(duration: 0.15), value: focusedSection)
                    .animation(.easeInOut(duration: 0.15), value: selectedSection)
                    .accessibilityAddTraits(isSelected ? [.isSelected] : [])
                    .accessibilityIdentifier("library.chip.\(sec.rawValue.lowercased())")
                    .focused($focusedSection, equals: sec)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial)
            .focusSection()
            .defaultFocus($focusedSection, selectedSection)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("library.chipBar")
            #else
            HStack(spacing: 6) {
                ForEach(LibrarySection.allCases) { sec in
                    let selected = selectedSection == sec
                    Button {
                        guard selectedSection != sec else { return }
                        iPocketTubeHaptics.shared.perform(.segmentSelection)
                        selectedSection = sec
                    } label: {
                        Text(verbatim: sec.localizedTitle)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .foregroundStyle(selected ? Color.black : iPocketTubeVisualTokens.secondaryText)
                            .background(selected ? iPocketTubeVisualTokens.mint : iPocketTubeVisualTokens.panelElevated, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .accessibilityIdentifier("library.picker.\(sec.rawValue.lowercased())")
                }
            }
            .iPocketTubeEDRPressEffect(
                enabled: store.settings.experimentalEDRPressGlowEnabled,
                cornerRadius: 12
            )
            .accessibilityIdentifier("library.sectionPicker")
            .padding(.horizontal, iPocketTubeVisualTokens.horizontalPadding)
            .padding(.bottom, 10)
            #endif

            Group {
                if selectedSection == .channels {
                    channelsContent
                } else if !auth.isSignedIn && selectedSection != .subscriptions {
                    segmentSignInPrompt
                } else if browseVM.isLoading && browseVM.videoGroups.flatMap({ $0.videos }).isEmpty {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if browseVM.videoGroups.flatMap({ $0.videos }).isEmpty && !browseVM.isLoading {
                    emptyLibraryView
                } else {
                    let videos = FeedCatalogPolicy.visibleVideos(
                        browseVM.videoGroups.flatMap { $0.videos },
                        showShorts: store.settings.showShorts
                    )
                    ScrollView {
                        // KVO reader — always present; writes to ScrollOffsetStore
                        // without triggering SwiftUI re-renders on every scroll tick.
                        #if os(iOS) || os(tvOS)
                        ScrollOffsetReader(store: scrollStore)
                            .frame(width: 0, height: 0)
                        #endif

                        if browseVM.isLoading && videos.isEmpty {
                            ProgressView().frame(maxWidth: .infinity).padding()
                        }
                        if selectedSection == .playlists, queueVideosCount > 0 {
                            currentQueueRow
                        }
                        VideoGridSection(
                            videos: videos,
                            onSelect: { video in
                                iPocketTubeHaptics.shared.perform(
                                    video.playlistId == video.id ? .playlistSelection : .contentSelection
                                )
                                if video.playlistId == video.id {
                                    selectedPlaylist = video
                                } else {
                                    #if os(iOS)
                                    playerRouter.open(video: video, api: api)
                                    #else
                                    selectedVideo = video
                                    #endif
                                }
                            },
                            loadMore: {
                                if let last = videos.last {
                                    browseVM.loadMoreIfNeeded(lastVideo: last)
                                }
                            },
                            catalogContext: .mediaLibrary
                        )
                        // Offset restorer — always present; no-op when restoreOffset is nil.
                        #if os(iOS) || os(tvOS)
                        ScrollOffsetRestorer(targetOffset: restoreOffset) {
                            restoreOffset = nil
                        }
                        .frame(width: 0, height: 0)
                        #endif

                        if browseVM.isLoading && !videos.isEmpty {
                            ProgressView().frame(maxWidth: .infinity).padding()
                        }
                    }
                    .refreshable {
                        browseVM.loadContent(
                            for: BrowseSection(
                                id: selectedSection.id,
                                title: selectedSection.rawValue,
                                type: selectedSection.browseSectionType
                            ),
                            refresh: true
                        )
                    }
                }
            }
        }
        .onChange(of: selectedSection) { _, section in
            browseVM.select(section: BrowseSection(
                id: section.id,
                title: section.rawValue,
                type: section.browseSectionType
            ))
        }
        #if os(tvOS)
        // tvOS: player is opened via navigationDestination(item: $selectedVideo).
        // Save offset when selectedVideo is set; restore when it clears.
        .onChange(of: selectedVideo) { old, new in
            if old == nil, new != nil {
                savedScrollOffset = scrollStore.scrollView?.contentOffset.y ?? 0
            } else if old != nil, new == nil, let saved = savedScrollOffset {
                restoreOffset = saved
                savedScrollOffset = nil
            }
        }
        #endif
        .onDisappear {
            // Snapshot scroll position whenever the Library view leaves the screen
            // (player opening, tab switch, navigation push). At onDisappear time the
            // UIScrollView is still in memory and contentOffset is accurate.
            #if os(iOS) || os(tvOS)
            if let offset = scrollStore.scrollView?.contentOffset.y, offset > 0 {
                savedScrollOffset = offset
            }
            #endif
        }
        .onAppear {
            browseVM.select(section: BrowseSection(
                id: selectedSection.id,
                title: selectedSection.rawValue,
                type: selectedSection.browseSectionType
            ))
            // Restore scroll position when returning from the player, another tab,
            // or any navigation that caused onDisappear to fire.
            #if os(iOS) || os(tvOS)
            if let saved = savedScrollOffset {
                restoreOffset = saved
                savedScrollOffset = nil
            }
            #endif
        }
        .task(id: selectedSection) {
            guard selectedSection == .playlists else { return }
            queueVideosCount = await CurrentQueueStore.shared.videos.count
        }
    }

    @ViewBuilder private var channelsContent: some View {
        if !auth.isSignedIn {
            VStack(spacing: 16) {
                Image(systemName: AppSymbol.personCircleQuestion)
                    .font(.system(size: 60))
                    .foregroundStyle(iPocketTubeVisualTokens.secondaryText)
                Text("Sign in to see your YouTube channels")
                    .font(.headline)
                    .foregroundStyle(iPocketTubeVisualTokens.secondaryText)
                    .multilineTextAlignment(.center)
                NavigationLink("Sign In") { SignInView() }
                    .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("library.channels.signIn")
        } else if browseVM.isLoading && browseVM.subscribedChannels.isEmpty {
            ProgressView("Loading channels…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("library.channels.loading")
        } else if browseVM.error != nil && browseVM.subscribedChannels.isEmpty {
            VStack(spacing: 14) {
                Image(systemName: "wifi.exclamationmark")
                    .font(.system(size: 44))
                    .foregroundStyle(iPocketTubeVisualTokens.secondaryText)
                Text("Could not load channels")
                    .font(.headline)
                Text("Check your connection and try again.")
                    .font(.subheadline)
                    .foregroundStyle(iPocketTubeVisualTokens.secondaryText)
                    .multilineTextAlignment(.center)
                Button("Retry") {
                    iPocketTubeHaptics.shared.perform(.downloadRetry)
                    reloadChannels()
                }
                    .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("library.channels.error")
        } else if browseVM.subscribedChannels.isEmpty {
            VStack(spacing: 14) {
                Image(systemName: "person.2.slash")
                    .font(.system(size: 44))
                    .foregroundStyle(iPocketTubeVisualTokens.secondaryText)
                Text("No subscribed channels")
                    .font(.headline)
                Text("Your YouTube subscriptions will appear here.")
                    .font(.subheadline)
                    .foregroundStyle(iPocketTubeVisualTokens.secondaryText)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("library.channels.empty")
        } else {
            ChannelListView(channels: browseVM.subscribedChannels) { channel in
                channelDestination = ChannelDestination(channelId: channel.id)
            }
            .refreshable { reloadChannels() }
            .accessibilityIdentifier("library.channels.list")
        }
    }

    private func reloadChannels() {
        browseVM.reload(section: BrowseSection(type: .channels))
    }

    @ViewBuilder private var currentQueueRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "list.number")
                .font(.title2)
                .frame(width: 44, height: 44)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("Current Queue")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)
                Text("\(queueVideosCount) videos")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture {
            iPocketTubeHaptics.shared.perform(.playlistSelection)
            selectedPlaylist = Video(
                id: CurrentQueueStore.playlistID,
                title: String(localized: "Current Queue", bundle: .module),
                channelTitle: ""
            )
        }
        .accessibilityIdentifier("library.currentQueueRow")
        Divider().padding(.horizontal)
    }

    @ViewBuilder private var emptyLibraryView: some View {
        if !auth.isSignedIn && selectedSection == .subscriptions {
            VStack(spacing: 16) {
                Image(systemName: "person.badge.plus")
                    .font(.system(size: 60))
                    .foregroundStyle(.secondary)
                Text("Follow channels to see their latest videos here")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Search") {
                    iPocketTubeHaptics.shared.perform(.primaryAction)
                    NotificationCenter.default.post(name: .navigateToSearch, object: nil)
                }
                .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 16) {
                Image(systemName: AppSymbol.stackLayers)
                    .font(.system(size: 60))
                    .foregroundStyle(.secondary)
                Text("Nothing here yet")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var segmentSignInPrompt: some View {
        VStack(spacing: 16) {
            Image(systemName: AppSymbol.personCircleQuestion)
                .font(.system(size: 60))
                .foregroundStyle(.secondary)
            Text("Sign in to see your \(selectedSection.localizedTitle.lowercased())")
                .font(.headline)
                .foregroundStyle(.secondary)
            NavigationLink("Sign In") {
                SignInView()
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
