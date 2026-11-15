#if os(iOS)
import SwiftUI
import iPocketTubeCore

typealias YTTab = MobileAppTab

extension MobileAppTab {
    var title: String {
        switch self {
        case .home: "Главная"
        case .shorts: "Shorts"
        case .subscriptions: "Подписки"
        case .you: "Вы"
        }
    }

    /// Outline icon; YouTube fills the icon of the selected tab.
    func icon(selected: Bool) -> String {
        switch self {
        case .home: selected ? "house.fill" : "house"
        case .shorts: selected ? "play.square.stack.fill" : "play.square.stack"
        case .subscriptions: selected ? "play.rectangle.on.rectangle.fill" : "play.rectangle.on.rectangle"
        case .you: selected ? "person.crop.circle.fill" : "person.crop.circle"
        }
    }

    var icon: String { icon(selected: false) }
}

/// Root of one tab: YouTube top bar, the tab content and a pushed search screen.
struct YTTabRoot: View {
    let tab: YTTab
    let isSelected: Bool
    @Binding var searchRequest: Int

    @Environment(\.innerTubeAPI) private var api
    @State private var showSearch = false
    @State private var showSettings = false
    @State private var channel: ChannelDestination?

    var body: some View {
        VStack(spacing: 0) {
            if tab != .shorts {
                YTTopBar(
                    onSearch: { showSearch = true },
                    onSettings: tab == .you ? { showSettings = true } : nil
                )
            }
            content
        }
        .background(tab == .shorts ? Color.black : YTColor.background)
        .overlay(alignment: .topTrailing) {
            if tab == .shorts {
                Button { showSearch = true } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 20))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .shadow(radius: 3)
                }
                .padding(.trailing, 6)
                .accessibilityLabel("Поиск")
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .navigationDestination(isPresented: $showSearch) {
            SearchView(onClose: { showSearch = false })
        }
        .navigationDestination(isPresented: $showSettings) {
            SettingsView()
        }
        .navigationDestination(item: $channel) { dest in
            ChannelView(channelId: dest.channelId, catalogContext: .standard)
        }
        .onChange(of: searchRequest) { _, _ in showSearch = true }
        .onReceive(NotificationCenter.default.publisher(for: .openChannel)) { note in
            // Only the visible tab navigates, so a channel never opens twice or off-screen.
            guard isSelected, let id = note.userInfo?["channelId"] as? String, !id.isEmpty else { return }
            channel = ChannelDestination(channelId: id)
        }
    }

    @ViewBuilder private var content: some View {
        switch tab {
        case .home: YTHomeFeedView(api: api)
        case .shorts:
            if isSelected { YTShortsTabView(api: api) } else { Color.black }
        case .subscriptions: YTSubscriptionsView(api: api)
        case .you: YTYouView()
        }
    }
}
#endif
