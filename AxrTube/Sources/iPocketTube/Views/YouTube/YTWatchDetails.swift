#if os(iOS)
import SwiftUI
import iPocketTubeCore

/// Everything under the 16:9 player on YouTube's portrait watch page.
struct YTWatchDetails: View {
    /// «Скачать» state: saving builds on the stream cache, so progress is
    /// the share already on disk.
    enum SaveState: Equatable {
        case none
        case saving(Double)
        case saved
    }

    struct Actions {
        var like: () -> Void
        var dislike: () -> Void
        var share: () -> Void
        var downloadVideo: () -> Void
        var downloadAudio: () -> Void
        var removeSaved: () -> Void
        var saveToWatchLater: () -> Void
        var transcript: () -> Void
        var description: () -> Void
        var comments: () -> Void
        var channel: () -> Void
        var subscribe: () -> Void
        var selectRelated: (Video) -> Void
    }

    let video: Video
    let related: [Video]
    let likeStatus: LikeStatus
    let owner: WatchOwnerInfo
    let isSubscribed: Bool
    let isSignedIn: Bool
    let saveState: SaveState
    let isDownloadingAudio: Bool
    let actions: Actions
    @State private var confirmRemove = false
    @Environment(SettingsStore.self) private var settingsStore
    private var edr: Bool { settingsStore.settings.experimentalEDRPressGlowEnabled }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                titleBlock
                channelRow
                actionChips
                commentsTeaser
                ForEach(related) { item in
                    YTVideoCard(video: item, onSelect: { actions.selectRelated(item) })
                }
            }
        }
        .background(YTColor.background)
        .scrollIndicators(.hidden)
        .confirmationDialog(
            saveState == .saved ? "Удалить из сохранённого?" : "Отменить сохранение?",
            isPresented: $confirmRemove, titleVisibility: .visible
        ) {
            Button(saveState == .saved ? "Удалить" : "Отменить сохранение", role: .destructive, action: actions.removeSaved)
            Button("Оставить", role: .cancel) {}
        }
    }

    // MARK: Sections

    private var titleBlock: some View {
        Button(action: actions.description) {
            VStack(alignment: .leading, spacing: 6) {
                Text(video.title)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(YTColor.primaryText)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
                (Text(metaLine) + Text("  ...ещё").fontWeight(.semibold).foregroundColor(YTColor.primaryText))
                    .font(.system(size: 12))
                    .foregroundStyle(YTColor.secondaryText)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.top, 12)
        }
        .buttonStyle(YTPressStyle())
        .accessibilityIdentifier("watch.title")
    }

    private var channelRow: some View {
        HStack(spacing: 10) {
            Button(action: actions.channel) {
                HStack(spacing: 10) {
                    avatar
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(owner.channelTitle ?? video.channelTitle)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(YTColor.primaryText)
                            .lineLimit(1)
                        if let subs = owner.subscriberText {
                            Text(Self.shortSubscribers(subs))
                                .font(.system(size: 12))
                                .foregroundStyle(YTColor.secondaryText)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(YTPressStyle())
            .disabled((owner.channelId ?? video.channelId ?? "").isEmpty)
            .accessibilityIdentifier("watch.channel")

            Button(action: actions.subscribe) {
                Text(isSubscribed ? "Вы подписаны" : "Подписаться")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(isSubscribed ? YTColor.primaryText : YTColor.chipSelectedText)
                    .padding(.horizontal, 14)
                    .frame(height: 36)
                    .background(isSubscribed ? YTColor.chip : YTColor.chipSelected, in: Capsule())
            }
            .buttonStyle(YTPressStyle())
            .ytEDRPress(edr && !isSubscribed, tint: .red)
            .disabled((owner.channelId ?? video.channelId ?? "").isEmpty)
            .accessibilityIdentifier("watch.subscribe")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
    }

    @ViewBuilder private var avatar: some View {
        CachedRemoteImage(url: owner.avatarURL) { image in
            Image(uiImage: image).resizable().scaledToFill()
        } placeholder: {
                YTChannelAvatar(title: owner.channelTitle ?? video.channelTitle, size: 36)
        }
        .frame(width: 36, height: 36)
        .clipShape(Circle())
    }

    private var actionChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                HStack(spacing: 0) {
                    chipButton(likeStatus == .like ? "hand.thumbsup.fill" : "hand.thumbsup", owner.likeCountText, action: actions.like)
                        .accessibilityLabel("Нравится")
                    Rectangle().fill(YTColor.divider).frame(width: 1, height: 20)
                    chipButton(likeStatus == .dislike ? "hand.thumbsdown.fill" : "hand.thumbsdown", nil, action: actions.dislike)
                        .accessibilityLabel("Не нравится")
                }
                .background(YTColor.chip, in: Capsule())
                .ytEDRPress(edr, tint: .white)
                chip("arrowshape.turn.up.right", "Поделиться", action: actions.share)
                saveChip
                    .ytEDRPress(edr, tint: .blue)
                .accessibilityIdentifier("watch.download")
                chip("text.quote", "Текст видео", action: actions.transcript)
                    .accessibilityIdentifier("watch.transcript")
            }
            .padding(.horizontal, 12)
        }
        .padding(.bottom, 12)
    }

    @ViewBuilder private var saveChip: some View {
        switch saveState {
        case .none:
            // Tap saves the video; long press offers the audio-only file.
            Menu {
                Button(action: actions.downloadAudio) { Label("Сохранить только звук", systemImage: "headphones") }
            } label: {
                chipLabel("bookmark", "Сохранить")
                    .background(YTColor.chip, in: Capsule())
            } primaryAction: {
                iPocketTubeHaptics.shared.perform(.primaryAction)
                actions.downloadVideo()
            }
        case .saving(let fraction):
            Button { confirmRemove = true } label: {
                HStack(spacing: 6) {
                    ZStack {
                        Circle().stroke(YTColor.divider, lineWidth: 2.5)
                        Circle().trim(from: 0, to: max(0.02, fraction))
                            .stroke(YTProgressLayers.cacheColor, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .animation(.linear(duration: 0.2), value: fraction)
                    }
                    .frame(width: 16, height: 16)
                    Text("\(Int((fraction * 100).rounded(.down)))%")
                        .font(.system(size: 14, weight: .medium).monospacedDigit())
                }
                .foregroundStyle(YTColor.primaryText)
                .padding(.horizontal, 14)
                .frame(height: 36)
                .background(YTColor.chip, in: Capsule())
            }
            .buttonStyle(YTPressStyle())
            .accessibilityLabel("Скачивается, \(Int(fraction * 100)) процентов")
        case .saved:
            Button { confirmRemove = true } label: {
                chipLabel("bookmark.fill", "Сохранено").background(YTColor.chip, in: Capsule())
            }
            .buttonStyle(YTPressStyle())
        }
    }

    private var commentsTeaser: some View {
        Button(action: actions.comments) {
            HStack {
                Text("Комментарии")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(YTColor.primaryText)
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 12))
                    .foregroundStyle(YTColor.secondaryText)
            }
            .padding(12)
            .background(YTColor.chip, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(.horizontal, 12)
            .padding(.bottom, 16)
        }
        .buttonStyle(YTPressStyle())
        .accessibilityIdentifier("watch.comments")
    }

    // MARK: Pieces

    private var metaLine: String {
        var parts: [String] = []
        if let views = video.viewCount { parts.append(YouTubeMetaFormatter.views(views)) }
        let published = VideoPublicationFormatter.string(for: video)
        if !published.isEmpty { parts.append(published) }
        return parts.joined(separator: "  ")
    }

    /// "1,2 млн подписчиков" → "1,2 млн", as YouTube prints it next to the name.
    static func shortSubscribers(_ text: String) -> String {
        let words = text.split(separator: " ")
        guard let last = words.last, last.lowercased().hasPrefix("подписчик") || last.lowercased().hasPrefix("subscriber") else {
            return text
        }
        return words.dropLast().joined(separator: " ")
    }

    private func chip(_ icon: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            chipLabel(icon, title).background(YTColor.chip, in: Capsule())
        }
        .buttonStyle(YTPressStyle())
    }

    private func chipButton(_ icon: String, _ title: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) { chipLabel(icon, title) }
            .buttonStyle(YTPressStyle())
    }

    private func chipLabel(_ icon: String, _ title: String?) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 15))
            if let title { Text(title).font(.system(size: 14, weight: .medium)) }
        }
        .foregroundStyle(YTColor.primaryText)
        .padding(.horizontal, 14)
        .frame(height: 36)
    }
}
#endif
