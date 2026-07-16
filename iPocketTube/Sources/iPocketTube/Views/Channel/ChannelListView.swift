import SwiftUI
import iPocketTubeCore

// MARK: - ChannelListView
//
// Displays the list of channels the authenticated user subscribes to.
// Shown when the "Channels" chip is selected in the Home chip bar.
// Mirrors the Android ChannelsBrowseFragment channel row layout.

struct ChannelListView: View {
    let channels: [Channel]
    let onSelect: (Channel) -> Void
    #if os(tvOS)
    @FocusState private var focusedChannelId: String?
    #endif

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(channels) { channel in
                    Button { onSelect(channel) } label: {
                        ChannelListRow(channel: channel)
                            #if os(tvOS)
                            .background(
                                focusedChannelId == channel.id
                                    ? Color.primary.opacity(0.12)
                                    : Color.clear
                            )
                            #endif
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("library.channel.\(channel.id)")
                    #if os(tvOS)
                    .focused($focusedChannelId, equals: channel.id)
                    #endif
                }
            }
            .padding(.horizontal, iPocketTubeVisualTokens.horizontalPadding)
            .padding(.vertical, 8)
        }
        #if os(tvOS)
        .focusSection()
        #endif
    }
}

// MARK: - ChannelListRow

private struct ChannelListRow: View {
    let channel: Channel

    var body: some View {
        HStack(spacing: 12) {
            avatar
            VStack(alignment: .leading, spacing: 2) {
                if channel.title.isEmpty {
                    Text("Unknown channel", bundle: .module)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                } else {
                    Text(verbatim: channel.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                }
                if let count = channel.subscriberCount {
                    Text(count)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(minHeight: 64)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(iPocketTubeVisualTokens.panelElevated, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(iPocketTubeVisualTokens.mint.opacity(0.22), lineWidth: 1)
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var avatar: some View {
        if let url = channel.thumbnailURL {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let img):
                    img.resizable()
                       .aspectRatio(contentMode: .fill)
                       .frame(width: 48, height: 48)
                       .clipShape(Circle())
                default:
                    avatarPlaceholder
                }
            }
            .frame(width: 48, height: 48)
        } else {
            avatarPlaceholder
        }
    }

    private var avatarPlaceholder: some View {
        Circle()
            .fill(Color.secondary.opacity(0.2))
            .frame(width: 48, height: 48)
            .overlay(
                Image(systemName: AppSymbol.personCircle)
                    .font(.title3)
                    .foregroundStyle(.secondary)
            )
    }
}
