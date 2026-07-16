import Foundation

/// Short heat / smooth cooling curve used by the iPocketTube press renderer.
/// It is pure so timing and non-rebound guarantees can be tested without UIKit.
public enum iPocketTubePressPulseEnvelope {
    public static let riseDuration: TimeInterval = 0.045
    public static let peakEnd: TimeInterval = 0.105
    public static let fadeDuration: TimeInterval = 0.72
    public static let totalDuration: TimeInterval = peakEnd + fadeDuration

    public static func heat(elapsed: TimeInterval, reduceMotion: Bool = false) -> Double {
        guard elapsed > 0 else { return 0 }
        let motionScale = reduceMotion ? 0.58 : 1.0
        let rise = riseDuration * motionScale
        let peak = peakEnd * motionScale
        let fade = fadeDuration * motionScale
        if elapsed < rise { return smootherStep(elapsed / rise) }
        if elapsed <= peak { return reduceMotion ? 0.58 : 1 }
        guard elapsed < peak + fade else { return 0 }
        let cooling = (elapsed - peak) / fade
        return (reduceMotion ? 0.58 : 1) * pow(max(1 - smootherStep(cooling), 0), 0.72)
    }

    private static func smootherStep(_ raw: Double) -> Double {
        let value = min(max(raw, 0), 1)
        return value * value * value * (value * (value * 6 - 15) + 10)
    }
}
