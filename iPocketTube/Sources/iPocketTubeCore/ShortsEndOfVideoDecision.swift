import Foundation

/// Pure end-of-video decision for the Shorts TOS embed player — what to do when
/// the embedded `<iframe>`'s `"stateChange"` message reports `ended`.
///
/// Mirrors `PlaybackViewModel.handlePlaybackEnd()`
/// (`PlaybackViewModel+Navigation.swift:114-163`), simplified for Shorts: no
/// queue/shuffle/related-videos concepts — just the linear `videos` array
/// `ShortsPlayerView` already pages through via `ShortsNavigation.targetIndex`.
/// Testable the same way: a pure function over `(settings, currentIndex, count)`,
/// no `WKWebView` required.
public enum ShortsEndOfVideoDecision: Equatable {
    /// `settings.loopEnabled` is on — seek the current Short back to 0 and replay
    /// (`ShortsEmbedPlayerViewModel.seekTo(0)` + `play()`).
    case replay
    /// Advance to `videos[to]` — same path as a swipe-up (`goTo(to)`).
    case advance(to: Int)
    /// At the end of `videos` with looping off — mirror today's "exhausted"
    /// behavior (`videoEnded = true`), freeze on the last frame.
    case freeze

    /// - Parameters:
    ///   - settings: Only `settings.loopEnabled` is consulted.
    ///   - currentIndex: Index of the Short that just ended.
    ///   - count: `videos.count`.
    public static func decide(settings: AppSettings, currentIndex: Int, count: Int) -> ShortsEndOfVideoDecision {
        if settings.loopEnabled {
            return .replay
        }
        let next = currentIndex + 1
        if next < count {
            return .advance(to: next)
        }
        return .freeze
    }
}
