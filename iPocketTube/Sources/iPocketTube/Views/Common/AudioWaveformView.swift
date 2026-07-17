#if os(iOS)
import AVFoundation
import CryptoKit
import Observation
import SwiftUI
import UIKit
import iPocketTubeCore

struct AudioWaveformSnapshot: Codable, Sendable, Equatable {
    let sourceSignature: String
    let peaks: [Float]
}

actor AudioWaveformRepository {
    static let shared = AudioWaveformRepository()

    func waveform(videoID: String, fileURL: URL, peakCount: Int = 360) async throws -> [Float] {
        let values = try fileURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let signature = "\(videoID)|\(values.fileSize ?? 0)|\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        let digest = SHA256.hash(data: Data(signature.utf8)).map { String(format: "%02x", $0) }.joined()
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("iPocketTubeWaveforms", isDirectory: true)
        let cacheURL = directory.appendingPathComponent("\(digest).json")
        if let data = try? Data(contentsOf: cacheURL),
           let cached = try? JSONDecoder().decode(AudioWaveformSnapshot.self, from: data),
           cached.sourceSignature == signature {
            return cached.peaks
        }

        let peaks = try await Self.extractPeaks(fileURL: fileURL, peakCount: peakCount)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(AudioWaveformSnapshot(sourceSignature: signature, peaks: peaks))
        try data.write(to: cacheURL, options: .atomic)
        return peaks
    }

    nonisolated static func extractPeaks(fileURL: URL, peakCount: Int) async throws -> [Float] {
        let asset = AVURLAsset(url: fileURL)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw NSError(domain: "iPocketTubeWaveform", code: 1)
        }
        let duration = try await asset.load(.duration).seconds
        let formats = try await track.load(.formatDescriptions)
        guard duration.isFinite, duration > 0,
              let format = formats.first,
              let description = CMAudioFormatDescriptionGetStreamBasicDescription(format) else {
            throw NSError(domain: "iPocketTubeWaveform", code: 2)
        }
        let sampleRate = max(1, description.pointee.mSampleRate)
        let channels = max(1, Int(description.pointee.mChannelsPerFrame))
        let totalFrames = max(1, Int64(duration * sampleRate))
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw NSError(domain: "iPocketTubeWaveform", code: 3) }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? NSError(domain: "iPocketTubeWaveform", code: 4) }

        var peaks = Array(repeating: Float.zero, count: max(64, peakCount))
        var frameOffset: Int64 = 0
        while reader.status == .reading, let sampleBuffer = output.copyNextSampleBuffer() {
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
                let sampleCount = length / MemoryLayout<Float>.size
                let values = UnsafeRawPointer(pointer).bindMemory(to: Float.self, capacity: sampleCount)
                let frameCount = sampleCount / channels
                for frame in 0..<frameCount {
                    var amplitude: Float = 0
                    for channel in 0..<channels {
                        amplitude = max(amplitude, abs(values[frame * channels + channel]))
                    }
                    let absoluteFrame = frameOffset + Int64(frame)
                    let bin = min(peaks.count - 1, Int(absoluteFrame * Int64(peaks.count) / totalFrames))
                    peaks[bin] = max(peaks[bin], min(1, amplitude))
                }
                frameOffset += Int64(frameCount)
            }
        }
        if reader.status == .failed { throw reader.error ?? NSError(domain: "iPocketTubeWaveform", code: 5) }
        let maximum = peaks.max() ?? 0
        guard maximum > 0 else { return peaks }
        return peaks.map { sqrt($0 / maximum) }
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
    @State private var peaks: [Float] = []
    @State private var isLoading = false
    @State private var gestureIntent: WaveformGestureIntent = .undecided
    @State private var frameDriver = WaveformFrameDriver()

    private var displayedTime: TimeInterval {
        isScrubbing ? playbackTime : frameDriver.displayedTime
    }

    var body: some View {
        VStack(spacing: 5) {
            GeometryReader { proxy in
                ZStack {
                    waveformCanvas(size: proxy.size)
                    if peaks.isEmpty {
                        Text(isLoading ? "Форма аудио готовится" : "Форма аудио недоступна")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
                .simultaneousGesture(seekDrag(width: proxy.size.width))
                .simultaneousGesture(SpatialTapGesture().onEnded { value in
                    seek(toX: value.location.x, width: proxy.size.width)
                })
            }
            .frame(height: 64)

            HStack {
                Text(formatPlaybackTime(displayedTime))
                Spacer()
                Text(duration > 0 ? "-\(formatPlaybackTime(max(0, duration - displayedTime)))" : "--:--")
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(iPocketTubeVisualTokens.secondaryText)
        }
        .frame(minHeight: 88)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Форма аудио и позиция воспроизведения")
        .accessibilityValue("\(formatPlaybackTime(displayedTime)) из \(formatPlaybackTime(duration))")
        .accessibilityAdjustableAction { direction in
            let delta: TimeInterval = direction == .increment ? 15 : -15
            commitAccessibleSeek(to: min(max(displayedTime + delta, 0), max(duration, 0)))
        }
        .task(id: "\(videoID)|\(fileVersion)") {
            guard FileManager.default.isReadableFile(atPath: fileURL.path) else { peaks = []; return }
            isLoading = true
            peaks = (try? await AudioWaveformRepository.shared.waveform(videoID: videoID, fileURL: fileURL)) ?? []
            isLoading = false
        }
        .onAppear { synchronizeDriver() }
        .onDisappear { frameDriver.stop() }
        .onChange(of: playbackTime) { _, _ in synchronizeDriver() }
        .onChange(of: isPlaying) { _, _ in synchronizeDriver() }
        .onChange(of: isScrubbing) { _, _ in synchronizeDriver() }
        .onChange(of: scenePhase) { _, _ in synchronizeDriver() }
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in synchronizeDriver() }
        .onReceive(NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)) { _ in synchronizeDriver() }
        .accessibilityIdentifier("downloads.audioWaveform")
    }

    private func waveformCanvas(size: CGSize) -> some View {
        Canvas { context, canvasSize in
            let mid = canvasSize.height / 2
            let progress = duration > 0 ? min(1, max(0, displayedTime / duration)) : 0
            let barCount = max(1, min(peaks.count, Int(canvasSize.width / 3)))
            if barCount > 0, !peaks.isEmpty {
                for index in 0..<barCount {
                    let source = min(peaks.count - 1, index * peaks.count / barCount)
                    let x = (CGFloat(index) + 0.5) * canvasSize.width / CGFloat(barCount)
                    let height = max(1, CGFloat(peaks[source]) * (canvasSize.height - 8))
                    var path = Path()
                    path.move(to: CGPoint(x: x, y: mid - height / 2))
                    path.addLine(to: CGPoint(x: x, y: mid + height / 2))
                    let fraction = Double(index) / Double(max(1, barCount - 1))
                    let color = fraction <= progress
                        ? iPocketTubeVisualTokens.mint
                        : (fraction <= bufferedProgress ? iPocketTubeVisualTokens.mintSoft.opacity(0.72) : iPocketTubeVisualTokens.secondaryText.opacity(0.3))
                    context.stroke(path, with: .color(color), lineWidth: 2)
                }
            } else {
                var line = Path()
                line.move(to: CGPoint(x: 0, y: mid))
                line.addLine(to: CGPoint(x: canvasSize.width, y: mid))
                context.stroke(line, with: .color(iPocketTubeVisualTokens.stroke), lineWidth: 1)
            }
            let playheadX = CGFloat(progress) * canvasSize.width
            var playhead = Path()
            playhead.move(to: CGPoint(x: playheadX, y: 0))
            playhead.addLine(to: CGPoint(x: playheadX, y: canvasSize.height))
            context.stroke(playhead, with: .color(iPocketTubeVisualTokens.mint), lineWidth: 2)
        }
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

    private func seek(toX x: CGFloat, width: CGFloat) {
        guard duration > 0 else { return }
        onScrubBegan()
        onScrubChanged(time(atX: x, width: width))
        onScrubEnded()
    }

    private func time(atX x: CGFloat, width: CGFloat) -> TimeInterval {
        guard width > 0, duration > 0 else { return 0 }
        return min(max(Double(x / width), 0), 1) * duration
    }

    private func commitAccessibleSeek(to time: TimeInterval) {
        onScrubBegan()
        onScrubChanged(time)
        onScrubEnded()
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
#endif
