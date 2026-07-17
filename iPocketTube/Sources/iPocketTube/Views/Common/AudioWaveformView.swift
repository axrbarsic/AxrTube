#if os(iOS)
import AVFoundation
import CryptoKit
import Observation
import SwiftUI
import UIKit
import iPocketTubeCore

fileprivate struct AudioScopeSnapshot: Codable, Sendable {
    let sourceSignature: String
    let start: TimeInterval
    let duration: TimeInterval
    let samples: [Float]
}

fileprivate struct AudioScopeFrame: Sendable {
    let window: LiveAudioScopeWindow
    let samples: [Float]
}

actor AudioWaveformRepository {
    static let shared = AudioWaveformRepository()

    private var memoryCache: [String: AudioScopeFrame] = [:]

    fileprivate func scopeWindow(
        videoID: String,
        fileURL: URL,
        centerTime: TimeInterval,
        assetDuration: TimeInterval,
        sampleCount: Int = 240
    ) async throws -> AudioScopeFrame {
        let values = try fileURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let signature = "\(videoID)|\(values.fileSize ?? 0)|\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        let bucket = LiveAudioScopePolicy.bucket(for: centerTime)
        let key = "\(signature)|\(bucket)|\(sampleCount)"
        if let cached = memoryCache[key] { return cached }

        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("iPocketTubeLiveScopes", isDirectory: true)
        let cacheURL = directory.appendingPathComponent("\(digest).json")
        if let data = try? Data(contentsOf: cacheURL),
           let cached = try? JSONDecoder().decode(AudioScopeSnapshot.self, from: data),
           cached.sourceSignature == signature {
            let frame = AudioScopeFrame(
                window: LiveAudioScopeWindow(start: cached.start, duration: cached.duration),
                samples: cached.samples
            )
            memoryCache[key] = frame
            return frame
        }

        let window = LiveAudioScopePolicy.analysisWindow(
            around: centerTime,
            assetDuration: assetDuration
        )
        let samples = try await Self.extractScope(
            fileURL: fileURL,
            window: window,
            sampleCount: sampleCount
        )
        let frame = AudioScopeFrame(window: window, samples: samples)
        memoryCache[key] = frame
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let snapshot = AudioScopeSnapshot(
            sourceSignature: signature,
            start: window.start,
            duration: window.duration,
            samples: samples
        )
        try JSONEncoder().encode(snapshot).write(to: cacheURL, options: .atomic)
        return frame
    }

    nonisolated private static func extractScope(
        fileURL: URL,
        window: LiveAudioScopeWindow,
        sampleCount: Int
    ) async throws -> [Float] {
        let asset = AVURLAsset(url: fileURL)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw NSError(domain: "iPocketTubeLiveScope", code: 1)
        }
        let formats = try await track.load(.formatDescriptions)
        guard let format = formats.first,
              let description = CMAudioFormatDescriptionGetStreamBasicDescription(format) else {
            throw NSError(domain: "iPocketTubeLiveScope", code: 2)
        }
        let sampleRate = max(1, description.pointee.mSampleRate)
        let channels = max(1, Int(description.pointee.mChannelsPerFrame))
        let bins = max(64, sampleCount)
        let totalFrames = max(1, Int64(window.duration * sampleRate))
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(
            start: CMTime(seconds: window.start, preferredTimescale: 600),
            duration: CMTime(seconds: window.duration, preferredTimescale: 600)
        )
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw NSError(domain: "iPocketTubeLiveScope", code: 3) }
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error ?? NSError(domain: "iPocketTubeLiveScope", code: 4)
        }

        var squareSums = Array(repeating: Double.zero, count: bins)
        var counts = Array(repeating: 0, count: bins)
        var peaks = Array(repeating: Float.zero, count: bins)
        var frameOffset: Int64 = 0
        while reader.status == .reading, let sampleBuffer = output.copyNextSampleBuffer() {
            if Task.isCancelled {
                reader.cancelReading()
                throw CancellationError()
            }
            autoreleasepool {
                guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
                var length = 0
                var pointer: UnsafeMutablePointer<Int8>?
                guard CMBlockBufferGetDataPointer(
                    block,
                    atOffset: 0,
                    lengthAtOffsetOut: nil,
                    totalLengthOut: &length,
                    dataPointerOut: &pointer
                ) == kCMBlockBufferNoErr, let pointer else { return }
                let scalarCount = length / MemoryLayout<Float>.size
                let values = UnsafeRawPointer(pointer).bindMemory(to: Float.self, capacity: scalarCount)
                let frameCount = scalarCount / channels
                for frame in 0..<frameCount {
                    var amplitude: Float = 0
                    for channel in 0..<channels {
                        amplitude = max(amplitude, abs(values[frame * channels + channel]))
                    }
                    let absoluteFrame = frameOffset + Int64(frame)
                    let bin = min(bins - 1, Int(absoluteFrame * Int64(bins) / totalFrames))
                    let bounded = min(max(amplitude, 0), 1)
                    squareSums[bin] += Double(bounded * bounded)
                    counts[bin] += 1
                    peaks[bin] = max(peaks[bin], bounded)
                }
                frameOffset += Int64(frameCount)
            }
        }
        if reader.status == .failed {
            throw reader.error ?? NSError(domain: "iPocketTubeLiveScope", code: 5)
        }
        let rms = squareSums.indices.map { index -> Float in
            guard counts[index] > 0 else { return 0 }
            return Float(sqrt(squareSums[index] / Double(counts[index])))
        }
        return LiveAudioScopePolicy.normalize(rms, peaks: peaks)
    }
}

@MainActor
@Observable
private final class WaveformFrameDriver {
    private(set) var displayedTime: TimeInterval = 0
    private var displayLink: CADisplayLink?
    private var anchorTime: TimeInterval = 0
    private var anchorTimestamp: CFTimeInterval = 0
    private var duration: TimeInterval = 0

    func synchronize(time: TimeInterval, duration: TimeInterval, running: Bool, reduceMotion: Bool) {
        displayedTime = min(max(time, 0), max(duration, 0))
        anchorTime = displayedTime
        self.duration = duration
        guard running, duration > 0 else { stop(); return }
        anchorTimestamp = CACurrentMediaTime()
        if displayLink == nil {
            let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
            let constrained = ProcessInfo.processInfo.isLowPowerModeEnabled
                || ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue
                || reduceMotion
            link.preferredFrameRateRange = constrained
                ? CAFrameRateRange(minimum: 20, maximum: 60, preferred: 30)
                : CAFrameRateRange(minimum: 30, maximum: 120, preferred: 120)
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        displayedTime = min(duration, anchorTime + max(0, link.timestamp - anchorTimestamp))
    }
}

struct AudioWaveformView: View {
    let videoID: String
    let fileURL: URL
    let fileVersion: Int64
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
    @State private var scope: AudioScopeFrame?
    @State private var isLoading = false
    @State private var frameDriver = WaveformFrameDriver()

    private var displayedTime: TimeInterval {
        isScrubbing ? playbackTime : frameDriver.displayedTime
    }

    private var scopeBucket: Int {
        LiveAudioScopePolicy.bucket(for: displayedTime)
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
        .task(id: "\(videoID)|\(fileVersion)|\(scopeBucket)|\(isPlaying)") {
            await loadScopeWindow()
        }
        .onAppear { synchronizeDriver() }
        .onDisappear { frameDriver.stop() }
        .onChange(of: playbackTime) { _, _ in synchronizeDriver() }
        .onChange(of: isPlaying) { _, playing in
            if !playing { isLoading = false }
            synchronizeDriver()
        }
        .onChange(of: isScrubbing) { _, _ in synchronizeDriver() }
        .onChange(of: scenePhase) { _, _ in synchronizeDriver() }
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in synchronizeDriver() }
        .onReceive(NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)) { _ in synchronizeDriver() }
        .accessibilityIdentifier("downloads.audioWaveform")
    }

    private var liveScope: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(iPocketTubeVisualTokens.panelElevated.opacity(0.6))
            if let scope {
                Canvas { context, size in
                    let bars = LiveAudioScopePolicy.visibleSamples(
                        from: scope.samples,
                        window: scope.window,
                        currentTime: displayedTime
                    )
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
            } else {
                HStack(spacing: 7) {
                    if isLoading { ProgressView().controlSize(.mini) }
                    Image(systemName: "waveform")
                    Text(isLoading ? "Анализ сигнала" : "Сигнал появится при воспроизведении")
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(iPocketTubeVisualTokens.secondaryText)
            }
        }
        .frame(height: 76)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Живой сигнал аудио")
        .accessibilityValue(scope == nil ? "Подготовка" : "Отображается")
    }

    private func loadScopeWindow() async {
        guard isPlaying, scenePhase == .active,
              duration.isFinite, duration > 0,
              FileManager.default.isReadableFile(atPath: fileURL.path) else { return }
        isLoading = scope == nil
        let requestedTime = displayedTime
        do {
            let frame = try await AudioWaveformRepository.shared.scopeWindow(
                videoID: videoID,
                fileURL: fileURL,
                centerTime: requestedTime,
                assetDuration: duration
            )
            try Task.checkCancellation()
            scope = frame
            isLoading = false
            _ = try? await AudioWaveformRepository.shared.scopeWindow(
                videoID: videoID,
                fileURL: fileURL,
                centerTime: min(duration, requestedTime + LiveAudioScopePolicy.bucketDuration),
                assetDuration: duration
            )
        } catch is CancellationError {
            return
        } catch {
            isLoading = false
        }
    }

    private func synchronizeDriver() {
        frameDriver.synchronize(
            time: playbackTime,
            duration: duration,
            running: isPlaying && !isScrubbing && scenePhase == .active,
            reduceMotion: reduceMotion
        )
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
