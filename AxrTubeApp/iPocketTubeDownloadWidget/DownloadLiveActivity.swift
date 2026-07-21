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
                PlaybackCompactProgressSegment(
                    state: context.state,
                    lowerBound: 0,
                    upperBound: 0.36
                )
            } compactTrailing: {
                PlaybackCompactProgressSegment(
                    state: context.state,
                    lowerBound: 0.36,
                    upperBound: 1
                )
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
    static let yellow = Color(red: 1.0, green: 0.78, blue: 0.12)
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
                Text("Прогресс")
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
            PlaybackModeContent(state: context.state)
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
            PlaybackModeContent(state: context.state)
                .foregroundStyle(.white.opacity(0.88))
        }
    }
}

@available(iOS 16.1, *)
private struct PlaybackModeContent: View {
    let state: PlaybackActivityAttributes.ContentState

    var body: some View {
        VStack(spacing: 4) {
            DualToneProgressBar(progress: state.progress)
                .frame(height: 6)
            HStack {
                Text(state.elapsed.axrDuration)
                Spacer()
                Text("-\(state.remaining.axrDuration)")
            }
            .font(.caption2.monospacedDigit())
        }
    }
}

@available(iOS 16.1, *)
private struct PlaybackTrailingView: View {
    let state: PlaybackActivityAttributes.ContentState

    var body: some View {
        Text(state.remaining.axrDuration)
            .font(.caption.monospacedDigit())
            .foregroundStyle(.white)
    }
}

@available(iOS 16.1, *)
private struct PlaybackCompactProgressSegment: View {
    let state: PlaybackActivityAttributes.ContentState
    let lowerBound: Double
    let upperBound: Double

    var body: some View {
        let fill = PlaybackLiveActivityPolicy.segmentFill(
            progress: state.progress,
            lowerBound: lowerBound,
            upperBound: upperBound
        )
        DualToneProgressBar(progress: fill)
            .frame(width: lowerBound == 0 ? 24 : 42, height: 6)
            .accessibilityLabel("Playback progress")
            .accessibilityValue("\(Int((state.progress * 100).rounded())) percent")
    }
}

@available(iOS 16.1, *)
private struct PlaybackMinimalView: View {
    let state: PlaybackActivityAttributes.ContentState

    var body: some View {
        ZStack {
            Circle().stroke(AxrTubePlaybackStyle.yellow, lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: state.progress)
                .stroke(AxrTubePlaybackStyle.green, style: StrokeStyle(lineWidth: 2.5, lineCap: .butt))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 15, height: 15)
        .accessibilityLabel("Playback progress")
        .accessibilityValue("\(Int((state.progress * 100).rounded())) percent")
    }
}

@available(iOS 16.1, *)
private struct DualToneProgressBar: View {
    let progress: Double

    var body: some View {
        GeometryReader { proxy in
            let width = max(0, proxy.size.width)
            ZStack(alignment: .leading) {
                Capsule().fill(AxrTubePlaybackStyle.yellow)
                Capsule()
                    .fill(AxrTubePlaybackStyle.green)
                    .frame(width: width * min(1, max(0, progress)))
            }
        }
        .clipShape(Capsule())
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
