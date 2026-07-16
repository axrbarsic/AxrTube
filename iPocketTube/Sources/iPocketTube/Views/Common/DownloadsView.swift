import SwiftUI
import iPocketTubeCore

/// The only owner of iPocketTube offline media and storage controls.
struct DownloadsView: View {
    @Environment(DownloadStore.self) private var downloadStore
    @Environment(VideoDownloadService.self) private var downloadService
    @Environment(SettingsStore.self) private var settingsStore
    @Environment(\.innerTubeAPI) private var api

    #if os(iOS)
    @Environment(PlayerRouter.self) private var playerRouter
    @Environment(PlayerStateStore.self) private var playerState
    #endif

    @State private var deleteConfirmationEntry: DownloadedVideo?
    @State private var showClearConfirmation = false

    var body: some View {
        #if os(iOS)
        iOSBody
        #else
        emptyState
        #endif
    }

    #if os(iOS)
    private var iOSBody: some View {
        VStack(spacing: 0) {
            collectionHeader
            if downloadStore.entries.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(sortedEntries) { entry in
                        Group {
                            if entry.videoId == playerRouter.audioFirst.currentVideo?.id,
                               entry.kind == (playerRouter.audioFirst.currentVideo?.localMediaKind ?? .audio) {
                                DownloadedNowPlayingCard(
                                    entry: entry,
                                    statusText: playerRouter.audioFirst.statusText,
                                    downloadProgress: playerRouter.audioFirst.downloadProgress,
                                    playbackTime: playerState.vm.isScrubbing ? playerState.vm.scrubTime : playerRouter.audioFirst.displayedPlaybackTime,
                                    playbackDuration: playerState.vm.duration,
                                    bufferedProgress: playerRouter.audioFirst.playbackBufferedProgress,
                                    isScrubbing: playerState.vm.isScrubbing,
                                    isPlaying: playerState.vm.isPlaying,
                                    onPlayPause: {
                                        iPocketTubeHaptics.shared.perform(.playbackTransport)
                                        playerRouter.audioFirst.togglePlayPauseByUser()
                                    },
                                    onScrubBegan: { playerRouter.audioFirst.beginScrubbing() },
                                    onScrubChanged: { playerRouter.audioFirst.updateScrubbing(to: $0) },
                                    onScrubEnded: {
                                        iPocketTubeHaptics.shared.perform(.seekCommit)
                                        playerRouter.audioFirst.commitScrubbing()
                                    },
                                    onRetry: { retry(entry) }
                                )
                            } else {
                                DownloadedMediaRow(
                                    entry: entry,
                                    edrEnabled: settingsStore.settings.experimentalEDRPressGlowEnabled,
                                    onRetry: { retry(entry) },
                                    onCancel: {
                                        iPocketTubeHaptics.shared.perform(.downloadPauseResume)
                                        playerRouter.audioFirst.pauseDownload(entry)
                                    },
                                    onPlay: {
                                        iPocketTubeHaptics.shared.perform(.downloadSelection)
                                        playerRouter.open(video: entry.video, api: api)
                                    }
                                )
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    guard entry.status == .completed else { return }
                                    iPocketTubeHaptics.shared.perform(.downloadSelection)
                                    playerRouter.open(video: entry.video, api: api)
                                }
                            }
                        }
                        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                iPocketTubeHaptics.shared.perform(.primaryAction)
                                deleteConfirmationEntry = entry
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        .contextMenu {
                            Button(role: .destructive) {
                                iPocketTubeHaptics.shared.perform(.primaryAction)
                                deleteConfirmationEntry = entry
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        .accessibilityIdentifier("downloads.mediaRow.\(entry.id)")
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .animation(.easeInOut(duration: 0.28), value: sortedEntries.map(\.id))
            }
        }
        .iPocketTubeScreenSurface()
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            playerRouter.audioFirst.reconcileDownloads(trigger: "downloads-screen")
        }
        .alert(
            "Delete Offline Item",
            isPresented: Binding(
                get: { deleteConfirmationEntry != nil },
                set: { if !$0 { deleteConfirmationEntry = nil } }
            )
        ) {
            Button("Delete", role: .destructive) {
                iPocketTubeHaptics.shared.perform(.downloadDelete)
                if let entry = deleteConfirmationEntry {
                    downloadStore.remove(videoId: entry.videoId, kind: entry.kind)
                }
                deleteConfirmationEntry = nil
            }
            Button("Cancel", role: .cancel) {
                iPocketTubeHaptics.shared.perform(.primaryAction)
                deleteConfirmationEntry = nil
            }
        } message: {
            Text("The local copy will be removed from this device.")
        }
        .alert("Clear Offline Collection", isPresented: $showClearConfirmation) {
            Button("Clear All", role: .destructive) {
                iPocketTubeHaptics.shared.perform(.downloadClear)
                downloadStore.clearAll()
            }
            Button("Cancel", role: .cancel) {
                iPocketTubeHaptics.shared.perform(.primaryAction)
            }
        } message: {
            Text("All downloaded video and audio files will be removed from iPocketTube.")
        }
    }

    private var collectionHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                iPocketTubeMatrixHeader(title: "Downloads")
                    .padding(.horizontal, -iPocketTubeVisualTokens.horizontalPadding)
                    .padding(.vertical, -6)
                Spacer(minLength: 8)
                Menu {
                    Picker("Storage Limit", selection: Binding(
                        get: { settingsStore.settings.offlineStorageLimitMB },
                        set: {
                            guard $0 != settingsStore.settings.offlineStorageLimitMB else { return }
                            iPocketTubeHaptics.shared.perform(.settingsPicker)
                            settingsStore.settings.offlineStorageLimitMB = $0
                        }
                    )) {
                        Text("1 GB").tag(1024)
                        Text("2 GB").tag(2048)
                        Text("4 GB").tag(4096)
                        Text("8 GB").tag(8192)
                        Text("16 GB").tag(16384)
                    }
                    if !downloadStore.entries.isEmpty {
                        Divider()
                        Button("Clear Offline Collection", role: .destructive) {
                            iPocketTubeHaptics.shared.perform(.primaryAction)
                            showClearConfirmation = true
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.headline)
                        .frame(width: 44, height: 44)
                        .background(iPocketTubeVisualTokens.panelElevated, in: Circle())
                }
                .accessibilityIdentifier("downloads.storageMenu")
            }

            HStack {
                Label(formattedBytes(downloadStore.totalSizeBytes), systemImage: "internaldrive")
                Spacer()
                Text(verbatim: "\(settingsStore.settings.offlineStorageLimitMB / 1024) GB")
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(iPocketTubeVisualTokens.secondaryText)

            ProgressView(
                value: min(1, Double(downloadStore.totalSizeBytes) / Double(max(1, settingsStore.settings.offlineStorageLimitMB) * 1024 * 1024))
            )
            .tint(iPocketTubeVisualTokens.mint)
        }
        .padding(.horizontal, iPocketTubeVisualTokens.horizontalPadding)
        .padding(.bottom, 10)
    }

    private func retry(_ entry: DownloadedVideo) {
        iPocketTubeHaptics.shared.perform(.downloadRetry)
        if entry.kind == .audio {
            playerRouter.open(video: entry.video, api: api)
            return
        }
        downloadService.retry(
            entry: entry,
            storageLimitMB: settingsStore.settings.offlineStorageLimitMB
        )
    }

    private var sortedEntries: [DownloadedVideo] {
        DownloadHistorySortPolicy.sorted(
            downloadStore.entries,
            currentItemID: currentItemID
        )
    }

    private var currentItemID: String? {
        guard let video = playerRouter.audioFirst.currentVideo ?? playerState.vm.currentVideo else { return nil }
        return "\(video.id)::\((video.localMediaKind ?? .audio).rawValue)"
    }
    #endif

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "arrow.down.to.line.compact")
                .font(.system(size: 44, weight: .medium))
                .foregroundStyle(iPocketTubeVisualTokens.mint)
            Text("No Offline Media")
                .font(.title3.bold())
            Text("Tap any video to save and play its audio. To save video, press and hold a card and choose Save Video.")
                .font(.subheadline)
                .foregroundStyle(iPocketTubeVisualTokens.secondaryText)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(28)
        .iPocketTubeCardSurface(cornerRadius: 20, contentPadding: 18)
        .padding(.horizontal, iPocketTubeVisualTokens.horizontalPadding)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("downloads.emptyState")
    }
}

#if os(iOS)
private struct DownloadedNowPlayingCard: View {
    let entry: DownloadedVideo
    let statusText: String
    let downloadProgress: Double
    let playbackTime: TimeInterval
    let playbackDuration: TimeInterval
    let bufferedProgress: Double
    let isScrubbing: Bool
    let isPlaying: Bool
    let onPlayPause: () -> Void
    let onScrubBegan: () -> Void
    let onScrubChanged: (TimeInterval) -> Void
    let onScrubEnded: () -> Void
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                mediaThumbnail(entry: entry, width: 112, height: 63)
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.title)
                        .font(.headline)
                        .lineLimit(2)
                    Text(entry.channelTitle)
                        .font(.caption)
                        .foregroundStyle(iPocketTubeVisualTokens.secondaryText)
                    Label(entry.kind == .audio ? "Audio" : "Video", systemImage: entry.kind == .audio ? "waveform" : "film")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(iPocketTubeVisualTokens.mintSoft)
                    if entry.status == .completed {
                        DownloadTimestampLabel(date: entry.downloadedAt)
                    }
                }
                Spacer(minLength: 0)
                Button(action: onPlayPause) {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.headline)
                        .foregroundStyle(.black)
                        .frame(width: 44, height: 44)
                        .background(iPocketTubeVisualTokens.mint, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isPlaying ? "Pause" : "Play")
            }

            if entry.status == .failed || entry.status == .cancelled {
                Text(failureDescription(entry))
                    .font(.caption)
                    .foregroundStyle(iPocketTubeVisualTokens.warning)
                    .lineLimit(2)
                Button("Retry", action: onRetry)
                    .buttonStyle(.borderedProminent)
                    .tint(iPocketTubeVisualTokens.mint)
                    .foregroundStyle(.black)
                    .frame(minHeight: 44)
            } else {
                playbackTimeline

                HStack {
                    Text(String(
                        format: String(localized: "Downloaded %d%%", bundle: .module),
                        Int(downloadProgress * 100)
                    ))
                        .font(.caption)
                        .foregroundStyle(iPocketTubeVisualTokens.secondaryText)
                    Spacer()
                    Text(statusText)
                        .font(.caption.monospacedDigit().weight(.bold))
                        .foregroundStyle(iPocketTubeVisualTokens.mint)
                }
                ProgressView(value: downloadProgress)
                    .tint(iPocketTubeVisualTokens.mint)
                    .scaleEffect(x: 1, y: 0.55, anchor: .center)
                if entry.status == .finalizationPending {
                    Button("Retry Offline Saving", action: onRetry)
                        .buttonStyle(.borderedProminent)
                        .tint(iPocketTubeVisualTokens.mint)
                        .foregroundStyle(.black)
                        .frame(minHeight: 44)
                }
            }
        }
        .iPocketTubeCardSurface(cornerRadius: 18, contentPadding: 14)
        .overlay(alignment: .topLeading) {
            Text("Now Playing")
                .font(.caption2.weight(.black))
                .textCase(.uppercase)
                .foregroundStyle(.black)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(iPocketTubeVisualTokens.mint, in: Capsule())
                .offset(x: 12, y: -8)
        }
        .accessibilityIdentifier("downloads.nowPlayingCard")
    }

    private var hasFiniteDuration: Bool {
        playbackDuration.isFinite && playbackDuration > 0
    }

    private var playbackTimeline: some View {
        VStack(spacing: 2) {
            ZStack {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(iPocketTubeVisualTokens.stroke)
                        Capsule()
                            .fill(iPocketTubeVisualTokens.mintSoft.opacity(0.55))
                            .frame(width: proxy.size.width * min(1, max(0, bufferedProgress)))
                    }
                    .frame(height: 4)
                    .frame(maxHeight: .infinity)
                }
                .frame(height: 44)
                .allowsHitTesting(false)

                Slider(
                    value: Binding(
                        get: { hasFiniteDuration ? min(playbackDuration, max(0, playbackTime)) : 0 },
                        set: { onScrubChanged($0) }
                    ),
                    in: 0...max(1, playbackDuration),
                    onEditingChanged: { editing in
                        if editing { onScrubBegan() } else { onScrubEnded() }
                    }
                )
                .tint(iPocketTubeVisualTokens.mint)
                .disabled(!hasFiniteDuration)
                .frame(minHeight: 44)
                .accessibilityLabel("Playback position")
                .accessibilityValue(hasFiniteDuration
                    ? String(
                        format: String(localized: "%@ of %@", bundle: .module),
                        formatPlaybackTime(playbackTime),
                        formatPlaybackTime(playbackDuration)
                    )
                    : String(localized: "Duration unavailable", bundle: .module))
                .accessibilityHint("Swipe up or down to seek")
            }

            HStack {
                Text(formatPlaybackTime(playbackTime))
                Spacer()
                Text(hasFiniteDuration ? "−\(formatPlaybackTime(max(0, playbackDuration - playbackTime)))" : "—:—")
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(iPocketTubeVisualTokens.secondaryText)
        }
        .accessibilityIdentifier("downloads.playbackScrubber")
    }
}

private struct DownloadedMediaRow: View {
    let entry: DownloadedVideo
    let edrEnabled: Bool
    let onRetry: () -> Void
    let onCancel: () -> Void
    let onPlay: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            mediaThumbnail(entry: entry, width: 100, height: 56)
            VStack(alignment: .leading, spacing: 5) {
                Text(entry.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                Text(entry.channelTitle)
                    .font(.caption)
                    .foregroundStyle(iPocketTubeVisualTokens.secondaryText)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    Label(entry.kind == .audio ? "Audio" : "Video", systemImage: entry.kind == .audio ? "waveform" : "film")
                    if entry.fileSizeBytes > 0 { Text(formattedBytes(entry.fileSizeBytes)) }
                }
                .font(.caption2)
                .foregroundStyle(iPocketTubeVisualTokens.mintSoft)
                if entry.status == .completed {
                    DownloadTimestampLabel(date: entry.downloadedAt)
                }
                statusContent
            }
            Spacer(minLength: 4)
            if entry.status == .completed {
                Button(action: onPlay) {
                    Image(systemName: "play.fill")
                        .frame(width: 44, height: 44)
                        .background(iPocketTubeVisualTokens.panelElevated, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Play")
            }
        }
        .iPocketTubeCardSurface(cornerRadius: 16, contentPadding: 12)
    }

    @ViewBuilder private var statusContent: some View {
        switch entry.status {
        case .completed:
            EmptyView()
        case .paused:
            VStack(alignment: .leading, spacing: 6) {
                Text(entry.resumePolicy == .manual ? "Download paused by you." : "Resuming automatically…")
                    .font(.caption2)
                    .foregroundStyle(iPocketTubeVisualTokens.secondaryText)
                if entry.resumePolicy == .manual {
                    Button("Continue", action: onRetry)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .tint(iPocketTubeVisualTokens.mint)
                        .foregroundStyle(.black)
                }
            }
        case .finalizationPending:
            VStack(alignment: .leading, spacing: 6) {
                Text("Playback is available. Offline saving needs retry.")
                    .font(.caption2)
                    .foregroundStyle(iPocketTubeVisualTokens.warning)
                Button("Retry Offline Saving", action: onRetry)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(iPocketTubeVisualTokens.mint)
                    .foregroundStyle(.black)
            }
        case .waitingForWiFi:
            Label("Waiting for Wi-Fi", systemImage: "wifi")
                .font(.caption2)
                .foregroundStyle(iPocketTubeVisualTokens.secondaryText)
        case .reconnecting:
            Label("Reconnecting…", systemImage: "arrow.triangle.2.circlepath")
                .font(.caption2)
                .foregroundStyle(iPocketTubeVisualTokens.secondaryText)
        case .failed, .cancelled:
            VStack(alignment: .leading, spacing: 6) {
                Text(failureDescription(entry))
                    .font(.caption2)
                    .foregroundStyle(iPocketTubeVisualTokens.warning)
                    .lineLimit(2)
                Button("Retry", action: onRetry)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(iPocketTubeVisualTokens.mint)
                    .foregroundStyle(.black)
                    .iPocketTubeEDRPressEffect(enabled: edrEnabled, cornerRadius: 8)
            }
        default:
            HStack(spacing: 8) {
                ProgressView(value: entry.progress)
                    .tint(iPocketTubeVisualTokens.mint)
                Button("Cancel", role: .destructive, action: onCancel)
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
        }
    }
}

private struct DownloadTimestampLabel: View {
    @Environment(\.locale) private var locale
    let date: Date?

    var body: some View {
        Label(displayText, systemImage: "clock.arrow.down")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(iPocketTubeVisualTokens.mintSoft)
            .lineLimit(1)
            .minimumScaleFactor(0.82)
            .accessibilityLabel(accessibilityText)
    }

    private var displayText: String {
        guard let date else {
            return String(localized: "Download time unknown", bundle: .module, locale: locale)
        }
        let time = formatted(date, dateStyle: .none, timeStyle: .short)
        switch DownloadTimestampPolicy.bucket(for: date) {
        case .today:
            return String(
                format: String(localized: "Downloaded today, %@", bundle: .module, locale: locale),
                locale: locale,
                time
            )
        case .yesterday:
            return String(
                format: String(localized: "Downloaded yesterday, %@", bundle: .module, locale: locale),
                locale: locale,
                time
            )
        case .earlier:
            let dateAndTime = formatted(date, dateStyle: .short, timeStyle: .short)
            return String(
                format: String(localized: "Downloaded %@", bundle: .module, locale: locale),
                locale: locale,
                dateAndTime
            )
        case .unknown:
            return String(localized: "Download time unknown", bundle: .module, locale: locale)
        }
    }

    private var accessibilityText: String {
        guard let date else { return displayText }
        return String(
            format: String(localized: "Downloaded %@", bundle: .module, locale: locale),
            locale: locale,
            formatted(date, dateStyle: .full, timeStyle: .short)
        )
    }

    private func formatted(
        _ date: Date,
        dateStyle: DateFormatter.Style,
        timeStyle: DateFormatter.Style
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateStyle = dateStyle
        formatter.timeStyle = timeStyle
        return formatter.string(from: date)
    }
}

private func mediaThumbnail(entry: DownloadedVideo, width: CGFloat, height: CGFloat) -> some View {
    AsyncImage(url: entry.thumbnailURL) { phase in
        if case .success(let image) = phase {
            image.resizable().aspectRatio(contentMode: .fill)
        } else {
            Rectangle().foregroundStyle(iPocketTubeVisualTokens.panelElevated)
                .overlay(Image(systemName: entry.kind == .audio ? "waveform" : "film").foregroundStyle(iPocketTubeVisualTokens.mintSoft))
        }
    }
    .frame(width: width, height: height)
    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
}

private func failureDescription(_ entry: DownloadedVideo) -> String {
    if entry.status == .cancelled {
        return String(localized: "Download cancelled.", bundle: .module)
    }
    if entry.errorMessage == "Download was interrupted. Tap Retry." {
        return String(localized: "Download was interrupted. Tap Retry.", bundle: .module)
    }
    return entry.errorMessage ?? String(localized: "Download failed.", bundle: .module)
}
#endif

private func formattedBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

private func formatPlaybackTime(_ seconds: TimeInterval) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "—:—" }
    let total = Int(seconds.rounded(.down))
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let remaining = total % 60
    if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, remaining) }
    return String(format: "%d:%02d", minutes, remaining)
}
