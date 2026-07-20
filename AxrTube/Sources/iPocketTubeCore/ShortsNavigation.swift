import Foundation

/// Pure swipe-navigation logic for the Shorts vertical-swipe player.
///
/// Separating this from the SwiftUI layer makes it fully unit-testable without
/// a running simulator or real Shorts content.
public enum ShortsNavigation {

    /// Returns the target index after a swipe gesture, or `nil` when the gesture
    /// should be ignored (too horizontal, below the distance threshold, or already
    /// at a boundary).
    ///
    /// - Parameters:
    ///   - vertical:   `value.translation.height` from a `DragGesture.Value`
    ///                 (negative = swipe up, positive = swipe down).
    ///   - horizontal: `abs(value.translation.width)` from a `DragGesture.Value`.
    ///   - current:    The currently displayed short index (0-based).
    ///   - count:      Total number of shorts in the list.
    public static func targetIndex(
        vertical: Double,
        horizontal: Double,
        current: Int,
        count: Int
    ) -> Int? {
        // Ignore gestures that are not predominantly vertical.
        guard abs(vertical) > horizontal else { return nil }

        if vertical < -40 {
            // Swipe up → advance to next short.
            let next = current + 1
            return next < count ? next : nil
        } else if vertical > 40 {
            // Swipe down → go back to previous short.
            let prev = current - 1
            return prev >= 0 ? prev : nil
        }

        return nil
    }
}
