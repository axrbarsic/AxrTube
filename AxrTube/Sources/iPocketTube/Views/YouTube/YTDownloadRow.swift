#if os(iOS)
import SwiftUI
import iPocketTubeCore

/// One «Скачанные» row in YouTube's style, identical for every source.
struct YTDownloadRow: View {
    struct Actions {
        var play: () -> Void
        var watchVideo: (() -> Void)?
        var transcript: () -> Void
        var pauseOrResume: (() -> Void)?
        var retry: (() -> Void)?
        var delete: () -> Void
    }

    let item: DownloadLibraryItem
    let isNowPlaying: Bool
    let actions: Actions

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: actions.play) {
                HStack(alignment: .top, spacing: 12) {
                    thumbnail
                    info
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(YTPressStyle())
            .disabled(!item.isPlayable)
            menu
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .accessibilityIdentifier("downloads.row.\(item.id)")
    }

    private var thumbnail: some View {
        ThumbnailFillView(primaryURL: item.thumbnailURL, fallbackURLs: [])
            .frame(width: 160, height: 90)
            .background(YTColor.placeholder)
            .overlay(alignment: .bottomTrailing) {
                HStack(spacing: 3) {
                    if item.isAudio { Image(systemName: "music.note") }
                    if item.duration > 0 { Text(formatDuration(item.duration)) }
                }
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 3))
                .padding(4)
            }
            .overlay(alignment: .bottom) {
                if let fraction = progress {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Rectangle().fill(.white.opacity(0.35))
                            Rectangle().fill(YTProgressLayers.cacheColor).frame(width: geo.size.width * fraction)
                        }
                        .frame(height: 4)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .opacity(item.state == .failed ? 0.5 : 1)
    }

    private var info: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.title)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(YTColor.primaryText)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Text(item.channelTitle)
                .font(.system(size: 12))
                .foregroundStyle(YTColor.secondaryText)
                .lineLimit(1)
            if isNowPlaying {
                Label("Сейчас играет", systemImage: "waveform")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(YTColor.brandRed)
            } else {
                Text(DownloadLibraryList.status(item))
                    .font(.system(size: 12, weight: item.state == .ready ? .regular : .medium))
                    .foregroundStyle(statusColor)
                    .lineLimit(1)
            }
        }
    }

    private var menu: some View {
        Menu {
            if item.isPlayable {
                Button(action: actions.play) { Label("Слушать", systemImage: "headphones") }
                if let watchVideo = actions.watchVideo {
                    Button(action: watchVideo) { Label("Смотреть видео", systemImage: "play.rectangle") }
                }
            }
            Button(action: actions.transcript) { Label("Текст видео", systemImage: "text.quote") }
            if let url = URL(string: "https://www.youtube.com/watch?v=\(item.videoID)") {
                ShareLink(item: url) { Label("Поделиться", systemImage: "arrowshape.turn.up.right") }
            }
            if let pauseOrResume = actions.pauseOrResume {
                Button(action: pauseOrResume) {
                    if case .paused = item.state {
                        Label("Продолжить", systemImage: "arrow.down.circle")
                    } else {
                        Label("Пауза", systemImage: "pause.circle")
                    }
                }
            }
            if let retry = actions.retry {
                Button(action: retry) { Label("Повторить", systemImage: "arrow.clockwise") }
            }
            Button(role: .destructive, action: actions.delete) {
                Label("Удалить из скачанных", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis")
                .rotationEffect(.degrees(90))
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(YTColor.primaryText)
                .frame(width: 32, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Действия")
    }

    private var progress: Double? {
        switch item.state {
        case .downloading(let p), .paused(let p): return min(max(p, 0), 1)
        default: return nil
        }
    }

    private var statusColor: Color {
        switch item.state {
        case .ready: YTColor.secondaryText
        case .downloading, .paused: YTProgressLayers.cacheColor
        case .failed: YTColor.brandRed
        }
    }
}
#endif
