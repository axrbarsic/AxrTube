import SwiftUI
import SmartTubeIOSCore

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
                } else if vm.isLoading || !vm.results.isEmpty {
                    resultsView
                } else if !vm.query.isEmpty {
                    noResultsView
                } else {
                    discoveryView
                }
                #endif
            }
        }
        .smartTubeScreenSurface()
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
        .onChange(of: isSearchFocused) { _, focused in
            if focused { Task { await vm.updateSuggestions(for: vm.query) } }
        }
    }

    // MARK: - Search bar

    private var compactSearchTitle: some View {
        Text("iPocketTube", bundle: .module)
            .font(.system(.title2, design: .rounded, weight: .heavy))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
            .padding(.horizontal, SmartTubeVisualTokens.horizontalPadding)
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
                .onSubmit { vm.search(); isSearchFocused = false }
            if !vm.query.isEmpty {
                Button {
                    vm.query = ""
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
                            vm.query = entry.query
                            vm.search()
                            isSearchFocused = false
                        } label: {
                            Label(entry.query, systemImage: "clock")
                        }
                    }
                    Divider()
                    Button("Clear History", role: .destructive) {
                        vm.clearHistory()
                    }
                }
            } label: {
                Image(systemName: "clock.arrow.circlepath")
                    .foregroundStyle(vm.history.isEmpty ? SmartTubeVisualTokens.secondaryText : SmartTubeVisualTokens.mintSoft)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Recent Searches")
            .accessibilityIdentifier("search.historyMenu")
            Button {
                showFilterSheet = true
            } label: {
                Image(systemName: vm.filter.isDefault ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                    .foregroundStyle(vm.filter.isDefault ? .secondary : Color.accentColor)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .smartTubeEDRPressEffect(
                enabled: store.settings.experimentalEDRPressGlowEnabled,
                cornerRadius: 22
            )
            .accessibilityIdentifier("search.filterButton")
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 44)
        .background(SmartTubeVisualTokens.panelElevated.opacity(0.95), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(SmartTubeVisualTokens.stroke, lineWidth: 0.8)
        }
        .padding(.horizontal, SmartTubeVisualTokens.horizontalPadding)
        .padding(.bottom, 4)
    }

    // MARK: - Discovery

    private var discoveryView: some View {
        // The former Home discovery feed now lives under the primary search
        // field, so discovery has one owner and one tab. Recent queries moved
        // into the clock menu beside the field and no longer consume height.
        HomeView(api: api)
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
                            var f = vm.filter; f.sortOrder = .relevance; vm.applyFilter(f)
                        }
                    }
                    if vm.filter.uploadDate != .anytime {
                        FilterChip(label: LocalizedStringKey(vm.filter.uploadDate.label)) {
                            var f = vm.filter; f.uploadDate = .anytime; vm.applyFilter(f)
                        }
                    }
                    if vm.filter.type != .any {
                        FilterChip(label: LocalizedStringKey(vm.filter.type.label)) {
                            var f = vm.filter; f.type = .any; vm.applyFilter(f)
                        }
                    }
                    if vm.filter.duration != .any {
                        FilterChip(label: LocalizedStringKey(vm.filter.duration.label)) {
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

    private var resultsView: some View {
        let hideLiveShorts = store.settings.hideLiveShorts
        let hideVideoPremieres = store.settings.hideVideoPremieres
        let displayResults = FeedCatalogPolicy.visibleVideos(
            vm.results,
            showShorts: store.settings.showShorts
        )
            .filter { !hideLiveShorts || !($0.isLive && $0.isShort) }
            .filter { !hideVideoPremieres || !$0.isUpcoming }
        return ScrollView {
            if vm.isLoading && vm.results.isEmpty {
                ProgressView().frame(maxWidth: .infinity).padding()
            }
            VideoGridSection(
                videos: displayResults,
                onSelect: { video in
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
                }

                Section("Upload date") {
                    Picker("Upload date", selection: $draft.uploadDate) {
                        ForEach(SearchFilter.UploadDate.allCases, id: \.self) { date in
                            Text(LocalizedStringKey(date.label)).tag(date)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }

                Section(String(localized: "search.filter.type", bundle: .module)) {
                    Picker(String(localized: "search.filter.type", bundle: .module), selection: $draft.type) {
                        ForEach(SearchFilter.VideoType.allCases, id: \.self) { type in
                            Text(LocalizedStringKey(type.label)).tag(type)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }

                Section("Duration") {
                    Picker("Duration", selection: $draft.duration) {
                        ForEach(SearchFilter.Duration.allCases, id: \.self) { dur in
                            Text(LocalizedStringKey(dur.label)).tag(dur)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
            }
            .navigationTitle("Search filters")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        onApply(draft)
                        dismiss()
                    }
                }
                #if os(iOS)
                ToolbarItem(placement: .bottomBar) {
                    Button("Reset") { draft = .default }
                        .disabled(draft.isDefault)
                }
                #endif
            }
        }
        .presentationDetents([.medium, .large])
        .accessibilityIdentifier("search.filterSheet")
    }
}
