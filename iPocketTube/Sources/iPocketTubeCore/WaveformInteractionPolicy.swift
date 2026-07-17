import Foundation

public enum WaveformGestureIntent: Equatable, Sendable {
    case undecided
    case seek
    case scroll
}

public enum WaveformGesturePolicy {
    public static func intent(
        horizontal: Double,
        vertical: Double,
        threshold: Double = 7
    ) -> WaveformGestureIntent {
        let x = abs(horizontal)
        let y = abs(vertical)
        guard max(x, y) >= threshold else { return .undecided }
        return x > y * 1.15 ? .seek : .scroll
    }
}

public struct LiveAudioScopeWindow: Equatable, Sendable {
    public let start: TimeInterval
    public let duration: TimeInterval

    public init(start: TimeInterval, duration: TimeInterval) {
        self.start = start
        self.duration = duration
    }
}

public enum LiveAudioScopePolicy {
    public static let analysisDuration: TimeInterval = 3
    public static let displayDuration: TimeInterval = 2
    public static let bucketDuration: TimeInterval = 1
    public static let silenceFloor: Float = 0.0015

    public static func bucket(for time: TimeInterval) -> Int {
        guard time.isFinite, time > 0 else { return 0 }
        return Int(floor(time / bucketDuration))
    }

    public static func analysisWindow(
        around time: TimeInterval,
        assetDuration: TimeInterval
    ) -> LiveAudioScopeWindow {
        guard assetDuration.isFinite, assetDuration > 0 else {
            return LiveAudioScopeWindow(start: 0, duration: analysisDuration)
        }
        let boundedTime = min(max(time, 0), assetDuration)
        let requestedStart = boundedTime - analysisDuration / 2
        let start = min(max(0, requestedStart), max(0, assetDuration - analysisDuration))
        return LiveAudioScopeWindow(
            start: start,
            duration: min(analysisDuration, assetDuration)
        )
    }

    /// Converts real RMS samples to a readable scope. Values below the physical
    /// noise floor stay at zero; speech and music use logarithmic gain followed
    /// by asymmetric attack/release smoothing.
    public static func normalize(_ rms: [Float], peaks: [Float]) -> [Float] {
        guard !rms.isEmpty else { return [] }
        let audible = rms.filter { $0 > silenceFloor }.sorted()
        let percentileIndex = max(0, Int(Double(audible.count - 1) * 0.9))
        let reference = max(0.008, audible.isEmpty ? 0.008 : audible[percentileIndex])
        let denominator = log1p(24.0)
        var previous: Float = 0
        return rms.indices.map { index in
            let value = max(0, rms[index])
            guard value > silenceFloor else {
                previous *= 0.72
                return previous < 0.015 ? 0 : previous
            }
            let peak = index < peaks.count ? max(0, peaks[index]) : value
            let scaledRMS = min(1, value / reference)
            let scaledPeak = min(1, peak / max(reference * 1.8, 0.012))
            let target = Float(log1p(Double((scaledRMS * 0.78 + scaledPeak * 0.22) * 24)) / denominator)
            let coefficient: Float = target >= previous ? 0.68 : 0.24
            previous += (target - previous) * coefficient
            return min(max(previous, 0), 1)
        }
    }

    public static func displaySamples(
        current: [Float],
        incoming: [Float],
        isPlaying: Bool
    ) -> [Float] {
        isPlaying ? incoming : current
    }

    public static func visibleSamples(
        from samples: [Float],
        window: LiveAudioScopeWindow,
        currentTime: TimeInterval,
        barCount: Int = 56
    ) -> [Float] {
        guard !samples.isEmpty, window.duration > 0, barCount > 0 else { return [] }
        let sampleStep = window.duration / Double(samples.count)
        let displayStart = currentTime - displayDuration / 2
        return (0..<barCount).map { index in
            let time = displayStart + Double(index) * displayDuration / Double(max(1, barCount - 1))
            let rawIndex = (time - window.start) / sampleStep
            let lower = min(max(Int(floor(rawIndex)), 0), samples.count - 1)
            let upper = min(lower + 1, samples.count - 1)
            let fraction = Float(min(max(rawIndex - Double(lower), 0), 1))
            return samples[lower] + (samples[upper] - samples[lower]) * fraction
        }
    }
}
