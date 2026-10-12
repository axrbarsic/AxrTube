#if os(iOS)
import SwiftUI
import iPocketTubeCore

/// Everything under the 16:9 player on YouTube's portrait watch page.
struct YTWatchDetails: View {
    struct Actions {
        var like: () -> Void
        var dislike: () -> Void
        var share: () -> Void
        var downloadVideo: () -> Void
        var downloadAudio: () -> Void
        var saveToWatchLater: () -> Void
        var transcript: () -> Void
        var description: () -> Void
        var comments: () -> Void
        var channel: () -> Void
        var selectRelated: (Video) -> Void
    }

    let video: Video
    let related: [Video]
    let likeStatus: LikeStatus
    let isSignedIn: Bool
    let isDownloading: Bool
    let actions: Actions

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                titleBlock
                channelRow
                actionChips
                commentsTeaser
                Divider().overlay(YTColor.divider).padding(.top, 4)
                ForEach(related) { item in
                    YTVideoCard(video: item, onSelect: { actions.selectRelated(item) })
                }
            }
        }
        .background(YTColor.background)
        .scrollIndicators(.hidden)
    }

    // MARK: Sections

    private var titleBlock: some View {
        Button(action: actions.description) {
            VStack(alignment: .leading, spacing: 6) {
                Text(video.title)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(YTColor.primaryText)
                    .multilineTextAlignment(.leading)
                    .lineLimit(3)
                HStack(spacing: 4) {
                    Text(metaLine)
                    Text("...ещё").fontWeight(.semibold)
                }
                .font(.system(size: 12))
                .foregroundStyle(YTColor.secondaryText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.top, 12)
        }
        .buttonStyle(YTPressStyle())
        .accessibilityIdentifier("watch.title")
    }

    private var channelRow: some View {
        Button(action: actions.channel) {
            HStack(spacing: 10) {
                YTChannelAvatar(title: video.channelTitle, size: 36)
                Text(video.channelTitle)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(YTColor.primaryText)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(YTPressStyle())
        .disabled((video.channelId ?? "").isEmpty)
        .accessibilityIdentifier("watch.channel")
    }

    private var actionChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if isSignedIn {
                    HStack(spacing: 0) {
                        chipButton(likeStatus == .like ? "hand.thumbsup.fill" : "hand.thumbsup", nil, action: actions.like)
                        Rectangle().fill(YTColor.divider).frame(width: 1, height: 20)
                        chipButton(likeStatus == .dislike ? "hand.thumbsdown.fill" : "hand.thumbsdown", nil, action: actions.dislike)
                    }
                    .background(YTColor.chip, in: Capsule())
                }
                chip("arrowshape.turn.up.right", "Поделиться", action: actions.share)
                Menu {
                    Button(action: actions.downloadVideo) { Label("Видео", systemImage: "film") }
                    Button(action: actions.downloadAudio) { Label("Только аудио", systemImage: "music.note") }
                } label: {
                    chipLabel(isDownloading ? "arrow.down.circle.dotted" : "arrow.down.to.line",
                              isDownloading ? "Скачивание…" : "Скачать")
                        .background(YTColor.chip, in: Capsule())
                }
                .accessibilityIdentifier("watch.download")
                chip("text.quote", "Текст видео", action: actions.transcript)
                if isSignedIn {
                    chip("clock", "Смотреть позже", action: actions.saveToWatchLater)
                }
            }
            .padding(.horizontal, 12)
        }
        .padding(.bottom, 12)
    }

    private var commentsTeaser: some View {
        Button(action: actions.comments) {
            HStack {
                Text("Комментарии")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(YTColor.primaryText)
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.system(size: 13))
                    .foregroundStyle(YTColor.secondaryText)
            }
            .padding(12)
            .background(YTColor.chip, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
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
        .frame(height: 34)
    }
}
#endif
