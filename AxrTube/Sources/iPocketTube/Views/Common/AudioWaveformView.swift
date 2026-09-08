#if os(iOS)
import Observation
import SwiftUI
import UIKit
import iPocketTubeCore

@MainActor
@Observable
final class WaveformFrameDriver {
    private(set) var displayedTime: TimeInterval = 0
    private(set) var scopeState = ProgressiveAudioScopeState()
    private(set) var displayedSamples: [Float] = []
    private(set) var waveform: [Float] = []
    private var displayLink: CADisplayLink?
    private var videoID = ""
    private var lastSnapshotSequence: UInt64 = 0
    private var previousSamples: [Float] = []
    private var targetSamples: [Float] = []
    private var transitionStartedAt: CFTimeInterval = 0
    private var lastTargetUpdateAt: CFTimeInterval = 0
    private var transitionDuration: CFTimeInterval = 1.0 / 30.0
    private var reduceMotion = false
    private var reportedFirstEnvelope = false

    func synchronize(
        videoID: String,
        time: TimeInterval,
        duration: TimeInterval,
        running: Bool,
        reduceMotion: Bool
    ) {
        if self.videoID != videoID {
            self.videoID = videoID
            scopeState = ProgressiveAudioScopeState()
            displayedSamples = []
            waveform = []
            previousSamples = []
            targetSamples = []
            lastSnapshotSequence = 0
            reportedFirstEnvelope = false
        }
        displayedTime = PlaybackPositionPolicy.displayedPosition(observed: time, duration: duration)
        self.reduceMotion = reduceMotion
        guard running else { stop(); return }
        updateScope(at: CACurrentMediaTime(), force: true)
        if displayLink == nil {
            let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
            let constrained = ProcessInfo.processInfo.isLowPowerModeEnabled
                || ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue
                || reduceMotion
            link.preferredFrameRateRange = constrained
                ? CAFrameRateRange(minimum: 20, maximum: 60, preferred: 30)
                : CAFrameRateRange(minimum: 30, maximum: 120, preferred: 120)
            transitionDuration = constrained ? 1.0 / 20.0 : 1.0 / 30.0
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        // The clock only follows AVPlayer observations. Rendering the scope must
        // not invent elapsed playback while a player is waiting for data or audio.
        updateScope(at: link.timestamp, force: false)
    }

    private func updateScope(at timestamp: CFTimeInterval, force: Bool) {
        if let snapshot = RealtimeAudioScopeRegistry.shared.snapshot(videoID: videoID),
           snapshot.sequence != lastSnapshotSequence,
           force || timestamp - lastTargetUpdateAt >= transitionDuration {
            let identityChanged = scopeState.identity != snapshot.identity
            waveform = snapshot.waveform
            scopeState.accept(identity: snapshot.identity, samples: snapshot.samples)
            let incoming = AudioScopeCadencePolicy.resample(scopeState.samples)
            if identityChanged || displayedSamples.isEmpty {
                previousSamples = incoming
                displayedSamples = incoming
            } else {
                previousSamples = displayedSamples
            }
            targetSamples = incoming
            transitionStartedAt = timestamp
            lastTargetUpdateAt = timestamp
            lastSnapshotSequence = snapshot.sequence
            if !reportedFirstEnvelope {
                reportedFirstEnvelope = true
                let progress = DownloadStore.shared.entry(videoId: videoID, kind: .video)?.progress ?? 0
                AudioDiagnostics.shared.record(
                    source: "audio-scope",
                    event: "pcm-tap.first-envelope",
                    decision: "download-percent=\(Int((progress * 100).rounded()))",
                    itemID: videoID
                )
            }
        }
        guard !targetSamples.isEmpty else { return }
        let progress = reduceMotion
            ? 1
            : min(1, max(0, (timestamp - transitionStartedAt) / transitionDuration))
        let interpolated = AudioScopeCadencePolicy.interpolate(
            from: previousSamples,
            to: targetSamples,
            progress: progress
        )
        if interpolated != displayedSamples { displayedSamples = interpolated }
    }
}

struct InlineAudioPulseView: View {
    @Environment(SettingsStore.self) private var settingsStore
    let videoID: String
    let playbackTime: TimeInterval
    let duration: TimeInterval
    let isPlaying: Bool

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var frameDriver = WaveformFrameDriver()

    var body: some View {
        Group {
            if frameDriver.scopeState.phase == .realEnvelope,
               !frameDriver.displayedSamples.isEmpty {
                if settingsStore.settings.oscilloscopeEnabled {
                    OscilloscopeCurve(samples: frameDriver.waveform)
                } else {
                Canvas { context, size in
                    let bars = frameDriver.displayedSamples
                    let spacing: CGFloat = 1.5
                    let width = max(2, (size.width - CGFloat(bars.count - 1) * spacing) / CGFloat(max(1, bars.count)))
                    for (index, sample) in bars.enumerated() where sample > 0 {
                        let height = max(3, CGFloat(sample) * size.height)
                        let rect = CGRect(
                            x: CGFloat(index) * (width + spacing),
                            y: (size.height - height) / 2,
                            width: width,
                            height: height
                        )
                        context.fill(
                            Path(roundedRect: rect, cornerRadius: width / 2),
                            with: .color(iPocketTubeVisualTokens.mint)
                        )
                    }
                }
                }
            } else {
                Image(systemName: "waveform")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(iPocketTubeVisualTokens.mint)
                    .symbolEffect(.variableColor.iterative, options: .repeating, isActive: isPlaying)
            }
        }
        .frame(width: 54, height: 22)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(.black.opacity(0.62), in: Capsule())
        .onAppear { synchronizeDriver() }
        .onDisappear { frameDriver.stop() }
        .onChange(of: playbackTime) { _, _ in synchronizeDriver() }
        .onChange(of: duration) { _, _ in synchronizeDriver() }
        .onChange(of: isPlaying) { _, _ in synchronizeDriver() }
        .onChange(of: scenePhase) { _, _ in synchronizeDriver() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Живой индикатор звука")
        .accessibilityValue(isPlaying ? "Работает" : "Пауза")
    }

    private func synchronizeDriver() {
        frameDriver.synchronize(
            videoID: videoID,
            time: playbackTime,
            duration: duration,
            running: isPlaying && scenePhase == .active,
            reduceMotion: reduceMotion
        )
    }
}

struct AudioWaveformView: View {
    @Environment(SettingsStore.self) private var settingsStore
    let videoID: String
    let playbackTime: TimeInterval
    let duration: TimeInterval
    let bufferedProgress: Double
    let isPlaying: Bool
    let isScrubbing: Bool
    let onScrubBegan: () -> Void
    let onScrubChanged: (TimeInterval) -> Void
    let onScrubEnded: () -> Void

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var frameDriver = WaveformFrameDriver()

    private var displayedTime: TimeInterval {
        isScrubbing ? playbackTime : frameDriver.displayedTime
    }

    var body: some View {
        VStack(spacing: 8) {
            liveScope
            AudioSeekControl(
                time: displayedTime,
                duration: duration,
                bufferedProgress: bufferedProgress,
                onScrubBegan: onScrubBegan,
                onScrubChanged: onScrubChanged,
                onScrubEnded: onScrubEnded
            )
        }
        .onAppear { synchronizeDriver() }
        .onDisappear { frameDriver.stop() }
        .onChange(of: playbackTime) { _, _ in synchronizeDriver() }
        .onChange(of: duration) { _, _ in synchronizeDriver() }
        .onChange(of: isPlaying) { _, _ in synchronizeDriver() }
        .onChange(of: isScrubbing) { _, _ in synchronizeDriver() }
        .onChange(of: scenePhase) { _, _ in synchronizeDriver() }
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in synchronizeDriver() }
        .onReceive(NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)) { _ in synchronizeDriver() }
        .accessibilityIdentifier("downloads.audioWaveform")
    }

    private var liveScope: some View {
        ZStack {
            if frameDriver.scopeState.phase == .realEnvelope,
               !frameDriver.displayedSamples.isEmpty {
                if settingsStore.settings.oscilloscopeEnabled {
                    OscilloscopeCurve(samples: frameDriver.waveform)
                } else {
                Canvas { context, size in
                    let bars = frameDriver.displayedSamples
                    let spacing: CGFloat = 2
                    let barWidth = max(2, (size.width - CGFloat(bars.count - 1) * spacing) / CGFloat(max(1, bars.count)))
                    let gradient = Gradient(colors: [
                        iPocketTubeVisualTokens.mintSoft,
                        iPocketTubeVisualTokens.mint,
                    ])
                    for (index, sample) in bars.enumerated() where sample > 0 {
                        let height = max(2, CGFloat(sample) * (size.height - 12))
                        let x = CGFloat(index) * (barWidth + spacing)
                        let rect = CGRect(x: x, y: (size.height - height) / 2, width: barWidth, height: height)
                        context.fill(
                            Path(roundedRect: rect, cornerRadius: barWidth / 2),
                            with: .linearGradient(
                                gradient,
                                startPoint: CGPoint(x: rect.midX, y: rect.maxY),
                                endPoint: CGPoint(x: rect.midX, y: rect.minY)
                            )
                        )
                    }
                }
                .padding(.horizontal, 8)
                .transition(.opacity)
                }
            } else {
                HStack(spacing: 7) {
                    Image(systemName: "waveform")
                    Text(isPlaying ? "Визуализация звука пока недоступна" : "Визуализация на паузе")
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(iPocketTubeVisualTokens.secondaryText)
                .transition(.opacity)
            }
        }
        .frame(height: 76)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: frameDriver.scopeState.phase)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Живой сигнал аудио")
        .accessibilityValue(
            frameDriver.scopeState.phase == .realEnvelope ? "Отображается" : "Подготовка"
        )
    }

    private func synchronizeDriver() {
        frameDriver.synchronize(
            videoID: videoID,
            time: playbackTime,
            duration: duration,
            running: isPlaying && !isScrubbing && scenePhase == .active,
            reduceMotion: reduceMotion
        )
    }
}

private struct OscilloscopeCurve: View {
    let samples: [Float]
    var body: some View {
        Canvas { context, size in
            guard samples.count > 1 else { return }
            var path = Path()
            for (index, sample) in samples.enumerated() {
                let point = CGPoint(
                    x: CGFloat(index) / CGFloat(samples.count - 1) * size.width,
                    y: size.height * (0.5 - CGFloat(sample) * 0.44)
                )
                if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            context.stroke(path, with: .color(iPocketTubeVisualTokens.mint), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }
        .accessibilityLabel("Осциллограф реального звука")
    }
}

private struct AudioSeekControl: View {
    let time: TimeInterval
    let duration: TimeInterval
    let bufferedProgress: Double
    let onScrubBegan: () -> Void
    let onScrubChanged: (TimeInterval) -> Void
    let onScrubEnded: () -> Void

    @State private var gestureIntent: WaveformGestureIntent = .undecided

    var body: some View {
        VStack(spacing: 2) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(iPocketTubeVisualTokens.stroke.opacity(0.8)).frame(height: 4)
                    Capsule()
                        .fill(iPocketTubeVisualTokens.mintSoft.opacity(0.55))
                        .frame(width: proxy.size.width * CGFloat(min(max(bufferedProgress, 0), 1)), height: 4)
                    Capsule()
                        .fill(iPocketTubeVisualTokens.mint)
                        .frame(width: proxy.size.width * CGFloat(progress), height: 4)
                    Circle()
                        .fill(iPocketTubeVisualTokens.mint)
                        .overlay(Circle().stroke(iPocketTubeVisualTokens.primaryText.opacity(0.65), lineWidth: 1))
                        .frame(width: 18, height: 18)
                        .offset(x: max(0, min(proxy.size.width - 18, proxy.size.width * CGFloat(progress) - 9)))
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .simultaneousGesture(seekDrag(width: proxy.size.width))
                .simultaneousGesture(SpatialTapGesture().onEnded { value in
                    commitSeek(atX: value.location.x, width: proxy.size.width)
                })
            }
            .frame(height: 44)

            HStack {
                Text(formatPlaybackTime(time))
                Spacer()
                Text(duration > 0 ? "-\(formatPlaybackTime(max(0, duration - time)))" : "--:--")
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(iPocketTubeVisualTokens.secondaryText)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Позиция воспроизведения")
        .accessibilityValue("\(formatPlaybackTime(time)) из \(formatPlaybackTime(duration))")
        .accessibilityAdjustableAction { direction in
            let delta: TimeInterval = direction == .increment ? 15 : -15
            commitSeek(to: min(max(time + delta, 0), max(duration, 0)))
        }
    }

    private var progress: Double {
        guard duration.isFinite, duration > 0, time.isFinite else { return 0 }
        return min(max(time / duration, 0), 1)
    }

    private func seekDrag(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 7)
            .onChanged { value in
                if gestureIntent == .undecided {
                    gestureIntent = WaveformGesturePolicy.intent(
                        horizontal: Double(value.translation.width),
                        vertical: Double(value.translation.height)
                    )
                    if gestureIntent == .seek { onScrubBegan() }
                }
                guard gestureIntent == .seek else { return }
                onScrubChanged(time(atX: value.location.x, width: width))
            }
            .onEnded { _ in
                if gestureIntent == .seek { onScrubEnded() }
                gestureIntent = .undecided
            }
    }

    private func commitSeek(atX x: CGFloat, width: CGFloat) {
        commitSeek(to: time(atX: x, width: width))
    }

    private func commitSeek(to target: TimeInterval) {
        guard duration > 0 else { return }
        onScrubBegan()
        onScrubChanged(target)
        onScrubEnded()
    }

    private func time(atX x: CGFloat, width: CGFloat) -> TimeInterval {
        guard width > 0, duration > 0 else { return 0 }
        return min(max(Double(x / width), 0), 1) * duration
    }
}
#endif
