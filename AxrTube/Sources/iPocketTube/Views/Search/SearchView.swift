import SwiftUI
import iPocketTubeCore

// MARK: - SearchView
//
// Search interface with live suggestions and paginated results.
// Mirrors the Android `SearchTagsActivity`.

public struct SearchView: View {
    @Environment(SearchViewModel.self) private var vm
    @Environment(\.innerTubeAPI) private var api
    @Environment(SettingsStore.self) private var store
    @State private var selectedVideo: Video?
    @State private var channelDestination: ChannelDestination?
    @State private var showFilterSheet = false
    @FocusState private var isSearchFocused: Bool
    #if os(iOS)
    @Environment(PlayerRouter.self) private var playerRouter
    #endif

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            compactSearchTitle
            searchBar
            if !vm.query.isEmpty {
                filterChipsRow
            }
            Group {
                #if os(tvOS)
                if vm.isLoading || !vm.results.isEmpty {
                    resultsView
                } else if vm.query.isEmpty {
                    suggestionsListView
                } else {
                    noResultsView
                }
                #else
                if isSearchFocused {
                    suggestionsListView
                } else if vm.hasActiveSearch && (vm.isLoading || !visibleSearchResults.isEmpty) {
                    resultsView
                } else if vm.hasActiveSearch {
                    noResultsView
                } else {
                    discoveryView
                }
                #endif
            }
        }
        .iPocketTubeScreenSurface()
        #if os(tvOS)
        .toolbar(.hidden, for: .navigationBar)
        .navigationDestination(item: $selectedVideo) { video in
            PlayerView(video: video, api: api)
        }
        #elseif os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        #endif
        .navigationDestination(item: $channelDestination) { dest in
            ChannelView(channelId: dest.channelId, catalogContext: .search)
        }
        .onReceive(NotificationCenter.default.publisher(for: .openChannel)) { note in
            guard let channelId = note.userInfo?["channelId"] as? String, !channelId.isEmpty else { return }
            channelDestination = ChannelDestination(channelId: channelId)
        }
        .sheet(isPresented: $showFilterSheet) {
            SearchFilterSheet(current: vm.filter) { newFilter in
                vm.applyFilter(newFilter)
            }
        }
        .task(id: vm.query) { await vm.updateSuggestions(for: vm.query) }
        .task(id: store.settings.russianOnlySearchEnabled) {
            vm.setRussianOnlySearchEnabled(store.settings.russianOnlySearchEnabled)
        }
        .onChange(of: isSearchFocused) { _, focused in
            if focused { Task { await vm.updateSuggestions(for: vm.query) } }
        }
        .onChange(of: vm.query) { _, newQuery in
            if newQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               vm.hasActiveSearch {
                vm.resetToDiscovery()
            }
        }
        .onAppear {
            if vm.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               vm.hasActiveSearch {
                vm.resetToDiscovery()
            }
        }
    }

    // MARK: - Search bar

    private var compactSearchTitle: some View {
        Text("AxrTube", bundle: .module)
            .font(.system(.title2, design: .rounded, weight: .heavy))
            .foregroundStyle(iPocketTubeVisualTokens.primaryText)
            .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
            .padding(.horizontal, iPocketTubeVisualTokens.horizontalPadding)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("search.compactTitle")
    }

    private var searchBar: some View {
        @Bindable var vm = vm
        return HStack(spacing: 8) {
            Image(systemName: AppSymbol.search)
                .foregroundStyle(.secondary)
            TextField("Search YouTube", text: $vm.query)
                .focused($isSearchFocused)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .accessibilityIdentifier("search.bar")
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .onSubmit {
                    iPocketTubeHaptics.shared.perform(.searchSubmit)
                    vm.search()
                    isSearchFocused = false
                }
            if !vm.query.isEmpty {
                Button {
                    iPocketTubeHaptics.shared.perform(.searchClear)
                    vm.resetToDiscovery()
                } label: {
                    Image(systemName: AppSymbol.xmarkCircle)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .frame(width: 44, height: 44)
                .accessibilityIdentifier("search.clearButton")
            }
            Menu {
                if vm.history.isEmpty {
                    Text("No Recent Searches", bundle: .module)
                } else {
                    ForEach(vm.history.prefix(10)) { entry in
                        Button {
                            iPocketTubeHaptics.shared.perform(.searchHistorySelection)
                            vm.query = entry.query
                            vm.search()
                            isSearchFocused = false
                        } label: {
                            Label(entry.query, systemImage: "clock")
                        }
                    }
                    Divider()
                    Button("Clear History", role: .destructive) {
                        iPocketTubeHaptics.shared.perform(.searchHistoryDelete)
                        vm.clearHistory()
                    }
                }
            } label: {
                Image(systemName: "clock.arrow.circlepath")
                    .foregroundStyle(vm.history.isEmpty ? iPocketTubeVisualTokens.secondaryText : iPocketTubeVisualTokens.mintSoft)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Recent Searches")
            .accessibilityIdentifier("search.historyMenu")
            Button {
                iPocketTubeHaptics.shared.perform(.filterPresentation)
                showFilterSheet = true
            } label: {
                Image(systemName: vm.filter.isDefault ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                    .foregroundStyle(vm.filter.isDefault ? .secondary : Color.accentColor)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .iPocketTubeEDRPressEffect(
                enabled: store.settings.experimentalEDRPressGlowEnabled,
                cornerRadius: 22
            )
            .accessibilityIdentifier("search.filterButton")
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 44)
        .iPocketTubeGlassSurface(cornerRadius: 16, interactive: true)
        .padding(.horizontal, iPocketTubeVisualTokens.horizontalPadding)
        .padding(.bottom, 4)
    }

    // MARK: - Discovery

    private var discoveryView: some View {
        // The former Home discovery feed now lives under the primary search
        // field, so discovery has one owner and one tab. Recent queries moved
        // into the clock menu beside the field and no longer consume height.
        HomeView(api: api)
            .id(vm.discoveryGeneration)
            .accessibilityIdentifier("search.discoveryFeed")
    }

    // MARK: - Active filter chips

    @ViewBuilder
    private var filterChipsRow: some View {
        if !vm.filter.isDefault {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    if vm.filter.sortOrder != .relevance {
                        FilterChip(label: LocalizedStringKey(vm.filter.sortOrder.label)) {
                            iPocketTubeHaptics.shared.perform(.filterChange)
                            var f = vm.filter; f.sortOrder = .relevance; vm.applyFilter(f)
                        }
                    }
                    if vm.filter.uploadDate != .anytime {
                        FilterChip(label: LocalizedStringKey(vm.filter.uploadDate.label)) {
                            iPocketTubeHaptics.shared.perform(.filterChange)
                            var f = vm.filter; f.uploadDate = .anytime; vm.applyFilter(f)
                        }
                    }
                    if vm.filter.type != .any {
                        FilterChip(label: LocalizedStringKey(vm.filter.type.label)) {
                            iPocketTubeHaptics.shared.perform(.filterChange)
                            var f = vm.filter; f.type = .any; vm.applyFilter(f)
                        }
                    }
                    if vm.filter.duration != .any {
                        FilterChip(label: LocalizedStringKey(vm.filter.duration.label)) {
                            iPocketTubeHaptics.shared.perform(.filterChange)
                            var f = vm.filter; f.duration = .any; vm.applyFilter(f)
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 6)
            }
            Divider()
        }
    }

    // MARK: - Results

    private var visibleSearchResults: [Video] {
        FeedCatalogPolicy.visibleVideos(
            vm.results,
            showShorts: store.settings.showShorts
        )
        .filter { !store.settings.hideLiveShorts || !($0.isLive && $0.isShort) }
        .filter { !store.settings.hideVideoPremieres || !$0.isUpcoming }
    }

    private var resultsView: some View {
        let displayResults = visibleSearchResults
        return ScrollView {
            if vm.isLoading && vm.results.isEmpty {
                ProgressView().frame(maxWidth: .infinity).padding()
            }
            VideoGridSection(
                videos: displayResults,
                onSelect: { video in
                    iPocketTubeHaptics.shared.perform(.contentSelection)
                    let captured = displayResults
                    Task { @MainActor in
                        await CurrentQueueStore.shared.replaceAll(with: captured)
                        let startIdx = captured.firstIndex(where: { $0.id == video.id }) ?? 0
                        let toPlay = await CurrentQueueStore.shared.videoAt(index: startIdx) ?? video
                        #if os(iOS)
                        playerRouter.open(video: toPlay, api: api)
                        #else
                        selectedVideo = toPlay
                        #endif
                    }
                },
                loadMore: vm.loadMore,
                catalogContext: .search
            )
            if vm.isLoading && !vm.results.isEmpty {
                ProgressView().frame(maxWidth: .infinity).padding()
            }
        }
        .refreshable { await vm.refreshSearch() }
        .accessibilityIdentifier("search.results")
        #if os(iOS)
        .scrollDismissesKeyboard(.immediately)
        .contentShape(Rectangle())
        .onTapGesture { isSearchFocused = false }
        #endif
    }

    // MARK: - Suggestions list (history + recommended/live)

    private var suggestionsListView: some View {
        let suggestionsHeader = vm.query.isEmpty ? "Recommended" : "Suggestions"
        return List {
            // History section — only shown when there are matching entries
            if !vm.filteredHistory.isEmpty {
                Section(header: Text("Recent").font(.caption).foregroundStyle(.secondary)) {
                    ForEach(vm.filteredHistory) { entry in
                        Button {
                            iPocketTubeHaptics.shared.perform(.searchHistorySelection)
                            vm.query = entry.query
                            vm.search()
                            isSearchFocused = false
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "clock")
                                    .foregroundStyle(.secondary)
                                    .frame(width: 20)
                                Text(entry.query)
                                    .foregroundStyle(.primary)
                                Spacer()
                                #if os(iOS)
                                Button {
                                    iPocketTubeHaptics.shared.perform(.searchHistoryDelete)
                                    vm.removeHistoryEntry(entry.query)
                                } label: {
                                    Image(systemName: AppSymbol.xmark)
                                        .foregroundStyle(.secondary)
                                        .font(.caption)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Remove \(entry.query) from history")
                                #endif
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("search.history.\(entry.query)")
                    }
                    Button(role: .destructive) {
                        iPocketTubeHaptics.shared.perform(.searchHistoryDelete)
                        vm.clearHistory()
                    } label: {
                        Text("Clear History")
                            .font(.subheadline)
                            .frame(maxWidth: .infinity)
                    }
                    .accessibilityIdentifier("search.history.clearAll")
                }
            }

            // Suggestions are supplied by YouTube for the active query. There
            // is deliberately no fabricated English fallback.
            if !vm.suggestions.isEmpty {
                Section(header: Text(LocalizedStringKey(suggestionsHeader), bundle: .module).font(.caption).foregroundStyle(.secondary)) {
                    ForEach(vm.suggestions, id: \.self) { suggestion in
                    Button {
                        iPocketTubeHaptics.shared.perform(.searchSuggestionSelection)
                        vm.query = suggestion
                        vm.search()
                        isSearchFocused = false
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: AppSymbol.search)
                                .foregroundStyle(.secondary)
                                .frame(width: 20)
                            Text(suggestion)
                                .foregroundStyle(.primary)
                            Spacer()
                            Button {
                                iPocketTubeHaptics.shared.perform(.searchSuggestionSelection)
                                vm.query = suggestion
                            } label: {
                                Image(systemName: "arrow.up.left")
                                    .foregroundStyle(.secondary)
                                    .font(.caption)
                            }
                            .buttonStyle(.plain)
                        }
                        .contentShape(Rectangle())
                    }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .listStyle(.plain)
        .accessibilityIdentifier("search.suggestionsContainer")
        // Tapping empty list space (outside a row) must dismiss the keyboard.
        // Task #202: the resultsView and noResultsView already had this gesture
        // but suggestionsListView (shown while keyboard is open) was missing it.
        // .contentShape(Rectangle()) makes the transparent empty space tappable.
        .contentShape(Rectangle())
        .onTapGesture { isSearchFocused = false }
    }

    private var placeholderView: some View {
        VStack(spacing: 16) {
            Image(systemName: AppSymbol.search)
                .font(.system(size: 60))
                .foregroundStyle(.secondary)
            Text("Search for videos, channels & playlists")
                .font(.headline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var noResultsView: some View {
        VStack(spacing: 16) {
            Image(systemName: AppSymbol.questionCircle)
                .font(.system(size: 60))
                .foregroundStyle(.secondary)
            Text("No results for \"\(vm.query)\"")
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
        #if os(iOS)
        .contentShape(Rectangle())
        .onTapGesture { isSearchFocused = false }
        #endif
    }
}

// MARK: - FilterChip

private struct FilterChip: View {
    let label: LocalizedStringKey
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.caption)
            Button(action: onRemove) {
                Image(systemName: AppSymbol.xmark)
                    .font(.caption2)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.tint.opacity(0.15), in: Capsule())
        .foregroundStyle(.tint)
    }
}

// MARK: - SearchFilterSheet

struct SearchFilterSheet: View {
    let current: SearchFilter
    let onApply: (SearchFilter) -> Void

    @State private var draft: SearchFilter
    @Environment(\.dismiss) private var dismiss

    init(current: SearchFilter, onApply: @escaping (SearchFilter) -> Void) {
        self.current = current
        self.onApply = onApply
        _draft = State(initialValue: current)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Sort by") {
                    Picker("Sort", selection: $draft.sortOrder) {
                        ForEach(SearchFilter.SortOrder.allCases, id: \.self) { order in
                            Text(LocalizedStringKey(order.label)).tag(order)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    .onChange(of: draft.sortOrder) { _, _ in
                        iPocketTubeHaptics.shared.perform(.filterChange)
                    }
                }

                Section("Upload date") {
                    Picker("Upload date", selection: $draft.uploadDate) {
                        ForEach(SearchFilter.UploadDate.allCases, id: \.self) { date in
                            Text(LocalizedStringKey(date.label)).tag(date)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    .onChange(of: draft.uploadDate) { _, _ in
                        iPocketTubeHaptics.shared.perform(.filterChange)
                    }
                }

                Section(String(localized: "search.filter.type", bundle: .module)) {
                    Picker(String(localized: "search.filter.type", bundle: .module), selection: $draft.type) {
                        ForEach(SearchFilter.VideoType.allCases, id: \.self) { type in
                            Text(LocalizedStringKey(type.label)).tag(type)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    .onChange(of: draft.type) { _, _ in
                        iPocketTubeHaptics.shared.perform(.filterChange)
                    }
                }

                Section("Duration") {
                    Picker("Duration", selection: $draft.duration) {
                        ForEach(SearchFilter.Duration.allCases, id: \.self) { dur in
                            Text(LocalizedStringKey(dur.label)).tag(dur)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    .onChange(of: draft.duration) { _, _ in
                        iPocketTubeHaptics.shared.perform(.filterChange)
                    }
                }
            }
            .navigationTitle("Search filters")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        iPocketTubeHaptics.shared.perform(.primaryAction)
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        iPocketTubeHaptics.shared.perform(.filterApply)
                        onApply(draft)
                        dismiss()
                    }
                }
                #if os(iOS)
                ToolbarItem(placement: .bottomBar) {
                    Button("Reset") {
                        iPocketTubeHaptics.shared.perform(.settingsReset)
                        draft = .default
                    }
                        .disabled(draft.isDefault)
                }
                #endif
            }
        }
        .presentationDetents([.medium, .large])
        .accessibilityIdentifier("search.filterSheet")
    }
}
