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
    public let audioFirst: AudioFirstPlaybackCoordinator
    public let playbackLiveActivity: PlaybackLiveActivityController
    public let transcriptSummary: TranscriptSummaryManager

    public init(
        playerState: PlayerStateStore,
        tosState: TOSPlayerStateStore,
        settingsStore: SettingsStore,
        api: InnerTubeAPI
    ) {
        self.playerState = playerState
        self.tosState = tosState
        let transcriptSummary = TranscriptSummaryManager()
        let playbackLiveActivity = PlaybackLiveActivityController(settingsStore: settingsStore)
        self.transcriptSummary = transcriptSummary
        self.playbackLiveActivity = playbackLiveActivity
        self.audioFirst = AudioFirstPlaybackCoordinator(
            api: api,
            playerState: playerState,
            settingsStore: settingsStore,
            playbackLiveActivity: playbackLiveActivity,
            transcriptSummary: transcriptSummary
        )
        transcriptSummary.onSummaryReady = { [weak playerState] videoID, text in
            playerState?.vm.applyNowPlayingSummary(videoID: videoID, text: text)
        }
    }

    /// The production tap contract is permanently audio-first. It never enters
    /// the fullscreen video/TOS route and therefore never executes YouTube's
    /// pre/mid/post-roll or end-card playback paths.
    public func open(video: Video, api: InnerTubeAPI) {
        if tosState.presentation != .hidden { tosState.stop() }
        switch AudioFirstPresentationPolicy.destination(for: video) {
        case .miniPlayer:
            audioFirst.open(video: video)
        }
    }

    public func closeAudioFirst() {
        audioFirst.close()
    }
}
#endif // os(iOS)
