import Foundation

// MARK: - Duration formatting
//
// Single source of truth for H:MM:SS / M:SS time formatting used by
// Video.formattedDuration and PlayerView's progress display.

/// Formats a `TimeInterval` as `H:MM:SS` (hours present) or `M:SS`.
/// Negative values are clamped to zero.
public func formatDuration(_ t: TimeInterval) -> String {
    let total = Int(max(t, 0))
    let h = total / 3600
    let m = (total % 3600) / 60
    let s = total % 60
    if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
    return String(format: "%d:%02d", m, s)
}
