#if os(iOS)
import SwiftUI
import iPocketTubeCore

/// Bottom tabs of the YouTube iOS app.
enum YTTab: String, CaseIterable, Identifiable {
    case home, shorts, subscriptions, you

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: "Главная"
        case .shorts: "Shorts"
        case .subscriptions: "Подписки"
        case .you: "Вы"
        }
    }

    var icon: String {
        switch self {
        case .home: "house"
        case .shorts: "play.square.stack"
        case .subscriptions: "play.rectangle.on.rectangle"
        case .you: "person.crop.circle"
        }
    }
}

/// Root of one tab: YouTube top bar, the tab content and a pushed search screen.
struct YTTabRoot: View {
    let tab: YTTab
    let isSelected: Bool
    @Binding var searchRequest: Int

    @Environment(\.innerTubeAPI) private var api
    @State private var showSearch = false
    @State private var channel: ChannelDestination?

    var body: some View {
        VStack(spacing: 0) {
            YTTopBar(title: tab == .you ? "Вы" : nil) { showSearch = true }
            content
        }
        .background(YTColor.background)
        .toolbar(.hidden, for: .navigationBar)
        .navigationDestination(isPresented: $showSearch) {
            SearchView(onClose: { showSearch = false })
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
        case .home: HomeView(api: api)
        case .shorts: YTFeedView(type: .shorts, requiresSignIn: false, api: api)
        case .subscriptions: YTFeedView(type: .subscriptions, requiresSignIn: true, api: api)
        case .you: YTYouView()
        }
    }
}
#endif
