#if os(iOS)
import Foundation
import iPocketTubeCore

// MARK: - PlayerRouter
//
// Single "open this video" decision point for iOS.
//
// Every place in the app that lets the user tap a video (Home, Search, Browse,
// Channel, Playlist, Library, RSS, and the deep-link / Share-Extension handlers
// in RootView) calls `open(video:api:)` instead of reaching into
// `PlayerStateStore` or `TOSPlayerStateStore` directly. That keeps the
// TOS-vs-AVPlayer routing decision — and the mini-player conflict rule — in one
// place instead of duplicated across every view.
//
// Routing rules:
//   - Production uses the AVPlayer-based pipeline so audio can survive a real
//     device lock and remain controllable through MPRemoteCommandCenter.
//   - Targeted TOS tests can opt into the WKWebView pipeline; a fatal embed error
//     still falls back to AVPlayer.
// In both cases, any active mini-player for the *other* pipeline is stopped
// first — AVPlayer and TOS playback are mutually exclusive.
@MainActor
@Observable
public final class PlayerRouter {
    private let playerState: PlayerStateStore
    private let tosState: TOSPlayerStateStore
    public let playbackLiveActivity: PlaybackLiveActivityController

    public init(
        playerState: PlayerStateStore,
        tosState: TOSPlayerStateStore,
        settingsStore: SettingsStore,
        api: InnerTubeAPI
    ) {
        self.playerState = playerState
        self.tosState = tosState
        let playbackLiveActivity = PlaybackLiveActivityController(settingsStore: settingsStore)
        self.playbackLiveActivity = playbackLiveActivity
    }

    /// One production route owns both streamed and downloaded video playback.
    /// A local file in `video.localFileURL` is consumed by the same AVPlayer
    /// owner, so opening an offline item never starts a second audio pipeline.
    public func open(video: Video, api: InnerTubeAPI) {
        if tosState.presentation != .hidden { tosState.stop() }
        playerState.play(video: video)
    }

    /// Starts playback in the feed thumbnail without presenting PlayerView.
    /// Uses the same AVPlayer owner as full-screen and downloaded playback.
    public func playInline(video: Video) {
        if tosState.presentation != .hidden { tosState.stop() }
        playerState.playInline(video: video)
    }

    public func closePlayback() {
        playerState.stop()
    }
}
#endif // os(iOS)
