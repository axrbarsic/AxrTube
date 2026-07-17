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
