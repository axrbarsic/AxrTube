#if os(iOS)
import SwiftUI
import iPocketTubeCore

/// YouTube channel header: avatar, name, subscriber count, description and
/// a full-width subscribe button. Signed-in accounts subscribe on YouTube;
/// guests follow the channel on this device.
struct YTChannelHeader: View {
    let channel: Channel
    @Binding var isFollowedLocally: Bool

    @Environment(AuthService.self) private var auth
    @Environment(\.innerTubeAPI) private var api
    @State private var isSubscribed: Bool?
    @State private var isChanging = false
    @State private var message: String?

    private var subscribed: Bool {
        auth.isSignedIn ? (isSubscribed ?? channel.isSubscribed) : isFollowedLocally
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                AsyncImage(url: channel.thumbnailURL) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFill()
                    } else {
                        YTChannelAvatar(title: channel.title, size: 72)
                    }
                }
                .frame(width: 72, height: 72)
                .clipShape(Circle())
                VStack(alignment: .leading, spacing: 4) {
                    Text(channel.title)
                        .font(.system(size: 22, weight: .bold))
                        .lineLimit(2)
                        .accessibilityIdentifier("channel.title")
                    if let subs = channel.subscriberCount {
                        Text(subs)
                            .font(.system(size: 13))
                            .foregroundStyle(YTColor.secondaryText)
                    }
                }
            }
            if let description = channel.description, !description.isEmpty {
                Text(description)
                    .font(.system(size: 13))
                    .foregroundStyle(YTColor.secondaryText)
                    .lineLimit(2)
            }
            Button { Task { await toggle() } } label: {
                Text(subscribed ? "Вы подписаны" : "Подписаться")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(subscribed ? YTColor.primaryText : YTColor.chipSelectedText)
                    .frame(maxWidth: .infinity)
                    .frame(height: 36)
                    .background(subscribed ? YTColor.chip : YTColor.chipSelected, in: Capsule())
            }
            .buttonStyle(YTPressStyle())
            .disabled(isChanging)
            .accessibilityIdentifier("channel.followButton")
            if let message {
                Text(message).font(.system(size: 12)).foregroundStyle(YTColor.secondaryText)
            }
        }
        .foregroundStyle(YTColor.primaryText)
        .padding(16)
        .accessibilityIdentifier("channel.header")
    }

    private func toggle() async {
        iPocketTubeHaptics.shared.perform(.primaryAction)
        isChanging = true
        defer { isChanging = false }
        message = nil
        let target = !subscribed
        if auth.isSignedIn {
            do {
                if target { try await api.subscribe(channelId: channel.id) } else { try await api.unsubscribe(channelId: channel.id) }
                isSubscribed = target
            } catch {
                message = "Не удалось изменить подписку"
            }
        } else if target {
            await LocalSubscriptionStore.shared.follow(LocalChannel(id: channel.id, title: channel.title, thumbnailURL: channel.thumbnailURL))
            isFollowedLocally = true
        } else {
            await LocalSubscriptionStore.shared.unfollow(channelId: channel.id)
            isFollowedLocally = false
        }
    }
}

/// YouTube channel tabs with the underline indicator.
struct YTChannelTabs: View {
    @Binding var selection: Int
    private let titles = ["Видео", "Shorts"]

    var body: some View {
        HStack(spacing: 24) {
            ForEach(titles.indices, id: \.self) { index in
                Button {
                    iPocketTubeHaptics.shared.perform(.segmentSelection)
                    selection = index
                } label: {
                    VStack(spacing: 8) {
                        Text(titles[index])
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(selection == index ? YTColor.primaryText : YTColor.secondaryText)
                        Rectangle()
                            .fill(selection == index ? YTColor.primaryText : .clear)
                            .frame(height: 2)
                    }
                    .fixedSize()
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .overlay(alignment: .bottom) { Rectangle().fill(YTColor.divider).frame(height: 0.5) }
        .padding(.bottom, 8)
        .accessibilityIdentifier("channel.filterPicker")
    }
}
/// A channel result at the top of YouTube search.
struct YTSearchChannelRow: View {
    let channel: Channel
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 16) {
                AsyncImage(url: channel.thumbnailURL) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFill()
                    } else {
                        YTChannelAvatar(title: channel.title, size: 88)
                    }
                }
                .frame(width: 88, height: 88)
                .clipShape(Circle())
                .padding(.leading, 28)
                VStack(alignment: .leading, spacing: 4) {
                    Text(channel.title)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(YTColor.primaryText)
                        .lineLimit(2)
                    if let meta = channel.subscriberCount {
                        Text(meta)
                            .font(.system(size: 12))
                            .foregroundStyle(YTColor.secondaryText)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(YTPressStyle())
        .accessibilityIdentifier("search.channel.\(channel.id)")
    }
}
#endif
