#if os(iOS)
import SwiftUI
import iPocketTubeCore

/// PWA-style subscriptions entry point, using the existing native catalog and
/// pin store. A guest sees locally followed/bookmarked channels, not a login wall.
struct YTChannelsView: View {
    @Environment(AuthService.self) private var auth
    @State private var vm: BrowseViewModel
    @State private var pins = PinnedChannelStore.shared
    @State private var channel: ChannelDestination?
    @State private var loadedInitial = false

    init(api: InnerTubeAPI) {
        _vm = State(initialValue: BrowseViewModel(api: api, initialSection: BrowseSection(type: .channels)))
    }

    private var channels: [Channel] { pins.orderedChannels(vm.subscribedChannels) }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                Text("Подписки")
                    .font(.system(size: 24, weight: .bold))
                    .padding(.vertical, 16)
                Text(auth.isSignedIn ? "Каналы YouTube. Закреплённые остаются наверху." : "Каналы на этом устройстве. Закреплённые остаются наверху.")
                    .font(.system(size: 13))
                    .foregroundStyle(YTColor.secondaryText)
                    .padding(.bottom, 16)

                if !loadedInitial || vm.isLoading { ProgressView().frame(maxWidth: .infinity).padding() }
                if vm.error != nil {
                    Text("Не удалось обновить список каналов. Сохранённые закрепления доступны ниже.")
                        .foregroundStyle(YTColor.secondaryText)
                    Button("Повторить") { reload() }
                        .frame(minHeight: 44)
                        .padding(.bottom, 12)
                }

                if channels.isEmpty && loadedInitial && !vm.isLoading && vm.error == nil {
                    Text("Здесь пока нет каналов")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 120)
                } else {
                    channelSection("Закреплённые", items: channels.filter { pins.contains($0.id) })
                    channelSection("Все каналы", items: channels.filter { !pins.contains($0.id) })
                }
            }
            .padding(.horizontal, 16)
        }
        .foregroundStyle(YTColor.primaryText)
        .background(YTColor.background)
        .refreshable { reload() }
        .task(id: auth.authSnapshot) {
            let snapshot = auth.authSnapshot
            let first = !loadedInitial
            await vm.applyAuthSnapshot(snapshot)
            guard !Task.isCancelled else { return }
            loadedInitial = true
            // applyAuthSnapshot starts the signed-in fetch itself. Only a cold
            // guest needs an explicit initial load, avoiding duplicate requests.
            if first && snapshot.accessToken == nil {
                vm.loadContent(for: BrowseSection(type: .channels), source: "pwa-channels.initialGuest")
            }
        }
        .navigationDestination(item: $channel) { destination in
            ChannelView(channelId: destination.channelId, catalogContext: .mediaLibrary)
        }
        .accessibilityIdentifier("subscriptions.channels")
    }

    private func reload() { vm.reload(section: BrowseSection(type: .channels)) }

    @ViewBuilder private func channelSection(_ title: String, items: [Channel]) -> some View {
        if !items.isEmpty {
            Text(title).font(.system(size: 20, weight: .bold)).padding(.vertical, 14)
            ForEach(items) { item in
                HStack(spacing: 8) {
                    Button {
                        channel = ChannelDestination(channelId: item.id)
                    } label: {
                        Text(item.title.isEmpty ? "Канал" : item.title)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .accessibilityIdentifier("subscriptions.channel.\(item.id)")
                    Button { pins.toggle(item) } label: {
                        Image(systemName: pins.contains(item.id) ? "star.fill" : "star")
                            .font(.system(size: 24))
                            .foregroundStyle(pins.contains(item.id) ? Color.yellow : YTColor.primaryText)
                            .frame(width: 48, height: 48)
                    }
                    .accessibilityLabel("\(pins.contains(item.id) ? "Открепить" : "Закрепить"): \(item.title)")
                    .accessibilityAddTraits(pins.contains(item.id) ? [.isSelected] : [])
                }
                .buttonStyle(.plain)
                Rectangle().fill(YTColor.divider).frame(height: 1)
            }
        }
    }
}
#endif
