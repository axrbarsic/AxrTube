import ActivityKit
import SwiftUI
import WidgetKit
import iPocketTubeCore

// MARK: - DownloadLiveActivity
//
// Live Activity widget displayed in the Dynamic Island and on the Lock Screen
// while VideoDownloadService is downloading a video.
//
// Dynamic Island compact:  progress arc + "Downloading" label
// Dynamic Island minimal:  just the arc
// Lock Screen banner:      title + phase label + progress bar

@available(iOS 16.1, *)
struct DownloadLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DownloadActivityAttributes.self) { context in
            // Lock Screen / StandBy banner
            LockScreenView(context: context)
        } dynamicIsland: { context in
            DynamicIsland {
                // Expanded (long press)
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "arrow.down.to.line.circle.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(.white.opacity(0.9))
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    ZStack {
                        Circle()
                            .stroke(Color.white.opacity(0.25), lineWidth: 4)
                        Circle()
                            .trim(from: 0, to: context.state.phase == .downloading
                                  ? context.state.progress : 1)
                            .stroke(Color.white, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    }
                    .frame(width: 32, height: 32)
                    .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.attributes.videoTitle)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Text(context.state.phase.displayLabel)
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    .padding(.bottom, 6)
                }
            } compactLeading: {
                Image(systemName: "arrow.down.to.line.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.white)
            } compactTrailing: {
                // Circular progress arc
                ZStack {
                    Circle()
                        .stroke(Color.white.opacity(0.3), lineWidth: 2.5)
                    Circle()
                        .trim(from: 0, to: context.state.phase == .downloading
                              ? context.state.progress : 1)
                        .stroke(Color.white, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 16, height: 16)
            } minimal: {
                Image(systemName: "arrow.down.to.line.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.white)
            }
        }
    }
}

// MARK: - Playback Live Activity

@available(iOS 16.1, *)
struct PlaybackLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PlaybackActivityAttributes.self) { context in
            PlaybackLockScreenView(context: context)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    AxrTubePlaybackMark(isPlaying: context.state.isPlaying, size: 28)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    PlaybackTrailingView(state: context.state)
                        .frame(maxWidth: 92, alignment: .trailing)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    PlaybackExpandedBottomView(context: context)
                        .padding(.bottom, 5)
                }
            } compactLeading: {
                AxrTubePlaybackMark(isPlaying: context.state.isPlaying, size: 16)
            } compactTrailing: {
                PlaybackCompactTrailingView(state: context.state)
            } minimal: {
                PlaybackMinimalView(state: context.state)
            }
            .keylineTint(AxrTubePlaybackStyle.green)
        }
    }
}

@available(iOS 16.1, *)
private enum AxrTubePlaybackStyle {
    static let green = Color(red: 0.10, green: 0.78, blue: 0.28)
}

@available(iOS 16.1, *)
private struct AxrTubePlaybackMark: View {
    let isPlaying: Bool
    let size: CGFloat

    var body: some View {
        Image(systemName: isPlaying ? "play.rectangle.fill" : "pause.rectangle.fill")
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(AxrTubePlaybackStyle.green)
            .accessibilityLabel(isPlaying ? "AxrTube playing" : "AxrTube paused")
    }
}

@available(iOS 16.1, *)
private struct PlaybackLockScreenView: View {
    let context: ActivityViewContext<PlaybackActivityAttributes>

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                AxrTubePlaybackMark(isPlaying: context.state.isPlaying, size: 17)
                Text("AxrTube")
                    .font(.caption.weight(.semibold))
                Text(context.state.presentation.lockScreenLabel)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Image(systemName: context.state.isPlaying ? "play.fill" : "pause.fill")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            // ActivityKit always requires Lock Screen content when a Dynamic
            // Island activity exists. Keep this useful and mode-specific, but
            // do not repeat the system Now Playing title or transport controls.
            PlaybackModeContent(state: context.state, author: context.attributes.author)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .activityBackgroundTint(Color(.systemBackground).opacity(0.94))
        .activitySystemActionForegroundColor(.primary)
    }
}

@available(iOS 16.1, *)
private struct PlaybackExpandedBottomView: View {
    let context: ActivityViewContext<PlaybackActivityAttributes>

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(context.attributes.title.isEmpty ? "AxrTube" : context.attributes.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
            PlaybackModeContent(state: context.state, author: context.attributes.author)
                .foregroundStyle(.white.opacity(0.88))
        }
    }
}

@available(iOS 16.1, *)
private struct PlaybackModeContent: View {
    let state: PlaybackActivityAttributes.ContentState
    let author: String

    var body: some View {
        switch state.presentation {
        case .minimal:
            Text(author.isEmpty ? (state.isPlaying ? "Playing" : "Paused") : author)
                .font(.caption)
                .lineLimit(1)
        case .progress:
            VStack(spacing: 4) {
                ProgressView(value: state.progress)
                    .tint(AxrTubePlaybackStyle.green)
                HStack {
                    Text(state.elapsed.axrDuration)
                    Spacer()
                    Text("-\(state.remaining.axrDuration)")
                }
                .font(.caption2.monospacedDigit())
            }
        case .waveform:
            WaveformSnapshotView(levels: state.waveformLevels)
                .frame(height: 24)
        case .line:
            Text(state.line.isEmpty ? "AxrTube" : state.line)
                .font(.caption)
                .lineLimit(2)
        }
    }
}

@available(iOS 16.1, *)
private struct PlaybackTrailingView: View {
    let state: PlaybackActivityAttributes.ContentState

    var body: some View {
        switch state.presentation {
        case .progress:
            Text(state.remaining.axrDuration)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.white)
        case .waveform:
            WaveformSnapshotView(levels: Array(state.waveformLevels.prefix(5)))
                .frame(width: 54, height: 24)
        case .minimal, .line:
            Text(state.isPlaying ? "PLAY" : "PAUSE")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white.opacity(0.9))
        }
    }
}

@available(iOS 16.1, *)
private struct PlaybackCompactTrailingView: View {
    let state: PlaybackActivityAttributes.ContentState

    var body: some View {
        switch PlaybackLiveActivitySurfacePolicy.compactContent(for: state.presentation) {
        case .remainingTime:
            Text(state.remaining.axrDuration)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.white)
        case .waveform:
            WaveformSnapshotView(levels: Array(state.waveformLevels.prefix(4)))
                .frame(width: 32, height: 14)
        case .playbackState:
            Image(systemName: state.isPlaying ? "speaker.wave.2.fill" : "pause.fill")
                .font(.caption2)
                .foregroundStyle(.white)
        case .caption:
            Image(systemName: "captions.bubble.fill")
                .font(.caption2)
                .foregroundStyle(.white)
        }
    }
}

@available(iOS 16.1, *)
private struct PlaybackMinimalView: View {
    let state: PlaybackActivityAttributes.ContentState

    var body: some View {
        switch PlaybackLiveActivitySurfacePolicy.minimalContent(for: state.presentation) {
        case .brand:
            AxrTubePlaybackMark(isPlaying: state.isPlaying, size: 14)
        case .progress:
            ZStack {
                Circle().stroke(Color.white.opacity(0.28), lineWidth: 2)
                Circle()
                    .trim(from: 0, to: state.progress)
                    .stroke(AxrTubePlaybackStyle.green, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 15, height: 15)
        case .waveform:
            Image(systemName: "waveform")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(AxrTubePlaybackStyle.green)
        case .caption:
            Image(systemName: "captions.bubble.fill")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(AxrTubePlaybackStyle.green)
        }
    }
}

@available(iOS 16.1, *)
private struct WaveformSnapshotView: View {
    let levels: [Double]

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                Capsule()
                    .fill(AxrTubePlaybackStyle.green)
                    .frame(maxWidth: 5, maxHeight: CGFloat(max(4, 24 * min(1, max(0.1, level)))))
            }
        }
        .frame(maxHeight: .infinity)
        .accessibilityLabel("Wave snapshot")
    }
}

@available(iOS 16.1, *)
private extension PlaybackActivityAttributes.ContentState {
    var progress: Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, elapsed / duration))
    }

    var remaining: TimeInterval { max(0, duration - elapsed) }
}

@available(iOS 16.1, *)
private extension PlaybackLiveActivityPresentation {
    var lockScreenLabel: String {
        switch self {
        case .minimal: "Minimal"
        case .progress: "Progress"
        case .waveform: "Wave"
        case .line: "Line"
        }
    }
}

private extension TimeInterval {
    var axrDuration: String {
        let total = max(0, Int(self.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }
}

// MARK: - Lock Screen Banner View

@available(iOS 16.1, *)
private struct LockScreenView: View {
    let context: ActivityViewContext<DownloadActivityAttributes>

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.down.to.line.circle.fill")
                .font(.system(size: 36))
                .foregroundStyle(.primary)

            VStack(alignment: .leading, spacing: 4) {
                Text(context.attributes.videoTitle)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)

                Text(context.state.phase.displayLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if context.state.phase == .downloading {
                    ProgressView(value: context.state.progress)
                        .tint(.primary)
                }
            }
        }
        .padding(16)
        .activityBackgroundTint(Color(.systemBackground).opacity(0.9))
        .activitySystemActionForegroundColor(.primary)
    }
}

// MARK: - Phase display label

@available(iOS 16.1, *)
private extension DownloadActivityAttributes.DownloadContentState.Phase {
    var displayLabel: String {
        switch self {
        case .fetching:    return String(localized: "Preparing download…")
        case .downloading: return String(localized: "Downloading…")
        case .saving:      return String(localized: "Saving to Photos…")
        case .done:        return String(localized: "Saved to Photos")
        case .failed:      return String(localized: "Download failed")
        }
    }
}

// MARK: - Placeholder widget (required by WidgetKit)
//
// A WidgetKit extension containing only ActivityConfiguration (Live Activity)
// has no descriptors enumerable by SpringBoard, causing:
//   SBAvocadoDebuggingControllerErrorDomain "Failed to get descriptors for extensionBundleID"
// Adding a minimal StaticConfiguration satisfies the requirement.

@available(iOS 16.1, *)
private struct DownloadPlaceholderWidget: Widget {
    static let kind = "DownloadPlaceholderWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: PlaceholderProvider()) { _ in
            EmptyView()
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName(String(localized: "AxrTube Download"))
        .description(String(localized: "Shows download progress in the Dynamic Island."))
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

@available(iOS 16.1, *)
private struct PlaceholderProvider: TimelineProvider {
    func placeholder(in context: Context) -> PlaceholderEntry { PlaceholderEntry() }
    func getSnapshot(in context: Context, completion: @escaping (PlaceholderEntry) -> Void) { completion(PlaceholderEntry()) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<PlaceholderEntry>) -> Void) {
        completion(Timeline(entries: [PlaceholderEntry()], policy: .never))
    }
}

@available(iOS 16.1, *)
private struct PlaceholderEntry: TimelineEntry {
    let date = Date()
}

// MARK: - Widget Bundle entry point

@available(iOS 16.1, *)
@main
struct iPocketTubeDownloadWidgetBundle: WidgetBundle {
    var body: some Widget {
        DownloadPlaceholderWidget()
        DownloadLiveActivityWidget()
        PlaybackLiveActivityWidget()
    }
}
