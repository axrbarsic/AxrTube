#if os(iOS)
import SwiftUI
import iPocketTubeCore

/// YouTube "Далее": the autoplay switch, the user's queue (when playing from
/// it) and then recommendations. Tapping an item plays it in place.
struct YTUpNextPanel: View {
    let currentID: String?
    let related: [Video]
    let onSelect: (Video) -> Void
    let onClose: () -> Void

    @Environment(SettingsStore.self) private var store
    @State private var queue: [Video] = []

    var body: some View {
        @Bindable var store = store
        VStack(spacing: 0) {
            HStack {
                Text("Далее").font(.system(size: 18, weight: .bold))
                Spacer()
                Toggle("Автовоспроизведение", isOn: $store.settings.autoplayEnabled)
                    .labelsHidden()
                    .tint(YTColor.brandRed)
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 17)).frame(width: 40, height: 40)
                }
                .accessibilityLabel("Закрыть")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            Divider().overlay(YTColor.divider)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if !queue.isEmpty {
                        section("Очередь")
                        ForEach(queue) { item in
                            YTVideoCard(video: item, style: .row, onSelect: { onSelect(item) })
                                .opacity(item.id == currentID ? 0.5 : 1)
                        }
                        section("Рекомендации")
                    }
                    ForEach(related) { item in
                        YTVideoCard(video: item, style: .row, onSelect: { onSelect(item) })
                    }
                    if related.isEmpty && queue.isEmpty {
                        Text("Рекомендации пока не загрузились")
                            .font(.system(size: 14))
                            .foregroundStyle(YTColor.secondaryText)
                            .frame(maxWidth: .infinity)
                            .padding(32)
                    }
                }
                .padding(.vertical, 6)
            }
        }
        .foregroundStyle(YTColor.primaryText)
        .background(YTColor.background)
        .task { queue = await CurrentQueueStore.shared.videos }
        .accessibilityIdentifier("player.upNext")
    }

    private func section(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(YTColor.secondaryText)
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 4)
    }
}
#endif
