#if os(iOS)
import SwiftUI
import iPocketTubeCore

/// YouTube iOS video card. Tapping anywhere opens the watch page immediately;
/// there is no inline preview playback and no automatic offline save.
struct YTVideoCard: View {
    enum Style { case large, row }

    let video: Video
    var style: Style = .large
    var currentPlaylistId: String? = nil
    let onSelect: () -> Void

    @Environment(AuthService.self) private var authService
    @Environment(SettingsStore.self) private var store
    @State private var progress: Double?

    var body: some View {
        Button {
            iPocketTubeHaptics.shared.perform(.contentSelection)
            onSelect()
        } label: {
            switch style {
            case .large: largeLayout
            case .row: rowLayout
            }
        }
        .buttonStyle(YTPressStyle())
        .task(id: video.id) {
            progress = await VideoStateStore.shared.state(for: video.id)?.watchedFraction
            // Warm stream data while the card is on screen so the tap starts instantly.
            await VideoPreloadCache.shared.prefetch(
                videoId: video.id,
                sponsorCategories: store.settings.activeSponsorCategories,
                authToken: authService.accessToken,
                priority: .visible
            )
        }
        .accessibilityIdentifier("video.card.\(video.id)")
    }

    // MARK: Layouts

    private var largeLayout: some View {
        VStack(alignment: .leading, spacing: 0) {
            thumbnail.aspectRatio(16 / 9, contentMode: .fit)
            HStack(alignment: .top, spacing: 12) {
                YTChannelAvatar(title: video.channelTitle, size: 36)
                VStack(alignment: .leading, spacing: 4) {
                    Text(displayTitle)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(YTColor.primaryText)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(metaLine)
                        .font(.system(size: 12))
                        .foregroundStyle(YTColor.secondaryText)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
                YTVideoMenu(video: video, currentPlaylistId: currentPlaylistId)
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 18)
        }
        .contentShape(Rectangle())
    }

    private var rowLayout: some View {
        HStack(alignment: .top, spacing: 10) {
            thumbnail
                .frame(width: 168, height: 94.5)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(displayTitle)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(YTColor.primaryText)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                Text(metaLine)
                    .font(.system(size: 12))
                    .foregroundStyle(YTColor.secondaryText)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            YTVideoMenu(video: video, currentPlaylistId: currentPlaylistId)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    // MARK: Pieces

    private var thumbnail: some View {
        ThumbnailFillView(primaryURL: video.thumbnailURL, fallbackURLs: video.thumbnailFallbackURLs)
            .background(YTColor.placeholder)
            .overlay(alignment: .bottomTrailing) { durationBadge.padding(6) }
            .overlay(alignment: .bottom) { progressBar }
            .clipped()
    }

    @ViewBuilder
    private var durationBadge: some View {
        if video.isLive {
            badge("В ЭФИРЕ", background: YTColor.liveRed)
        } else if !video.formattedDuration.isEmpty {
            badge(video.formattedDuration, background: .black.opacity(0.8))
        }
    }

    private func badge(_ text: String, background: Color) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(background, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    }

    @ViewBuilder
    private var progressBar: some View {
        if let fraction = progress ?? video.watchProgress, fraction > 0.01 {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle().fill(.white.opacity(0.35))
                    Rectangle().fill(YTColor.brandRed)
                        .frame(width: geo.size.width * min(fraction, 1))
                }
            }
            .frame(height: 3)
        }
    }

    private var displayTitle: String {
        if store.settings.deArrowEnabled, let title = video.deArrowTitle, !title.isEmpty { return title }
        return video.title
    }

    private var metaLine: String {
        YouTubeMetaFormatter.metaLine(for: video, published: VideoPublicationFormatter.string(for: video))
    }
}

/// Subtle dim on press, like YouTube's cell highlight.
struct YTPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.6 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Channel avatar placeholder until channel thumbnails are parsed into `Video`.
struct YTChannelAvatar: View {
    let title: String
    let size: CGFloat

    var body: some View {
        Circle()
            .fill(YTColor.avatarFill(for: title))
            .frame(width: size, height: size)
            .overlay {
                Text(title.first.map { String($0).uppercased() } ?? "")
                    .font(.system(size: size * 0.45, weight: .medium))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)
    }
}
#endif
