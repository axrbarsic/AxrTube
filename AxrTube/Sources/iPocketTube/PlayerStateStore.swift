#if os(iOS)
import AVFoundation
import UIKit
import Observation
import iPocketTubeCore
import OSLog
import UniformTypeIdentifiers

private let storeLog = Logger(subsystem: "com.void.ipockettube.app", category: "PlayerStateStore")

// MARK: - PersistentPlayerHostView

/// A UIView that owns an AVPlayerLayer for the lifetime of the app.
/// Its reference lives in PlayerStateStore, so the layer — and the AVPlayer
/// connection — survive PlayerView dismiss/re-present cycles (mini-player).
///
/// Embed it as a subview in full-screen and mini-player contexts.
/// UIView.addSubview automatically removes it from the previous parent,
/// so no explicit removeFromSuperview is needed when transplanting.
final class PersistentPlayerHostView: UIView {

    let playerLayer = AVPlayerLayer()

    var videoGravity: AVLayerVideoGravity {
        get { playerLayer.videoGravity }
        set { playerLayer.videoGravity = newValue }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        playerLayer.backgroundColor = UIColor.black.cgColor
        layer.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        playerLayer.frame = bounds
    }
}

// MARK: - PlayerStateStore

/// Centralised iOS playback state for the in-app mini-player.
///
/// Owns the single `PlaybackViewModel` and `PersistentPlayerHostView` so they
/// survive PlayerView presentation/dismiss cycles. Injected as an environment
/// object at the `AppEntry` level; accessed via `@Environment(PlayerStateStore.self)`.
@MainActor
@Observable
public final class PlayerStateStore {

    // MARK: - Presentation state

    public enum Presentation: Equatable {
        case hidden
        case miniPlayer
        case fullScreen
    }

    public private(set) var presentation: Presentation = .hidden

    /// The video that is currently loaded or playing. Non-nil when presentation != .hidden.
    private(set) var currentVideo: Video? = nil

    /// The video whose frames the AVPlayer is actually rendering.
    ///
    /// During a load (`vm.isLoading == true`), `currentVideo` has already been updated to
    /// the newly selected video but `AVPlayerItem` may not be ready yet — the player layer
    /// is still showing the previous video's frames. `playingVideo` resolves this by
    /// returning the last-confirmed playing video while the new one is loading, so the
    /// MiniPlayer label stays in sync with the visual content.
    ///
    /// - When idle (`isLoading == false`): equals `currentVideo`.
    /// - When loading (`isLoading == true`) and there is a previous video: equals that
    ///   video (last entry in `vm.history` — pushed onto the stack just before the new
    ///   video starts loading).
    /// - When loading the very first video ever (history is empty): returns `nil` (the
    ///   MiniPlayer is hidden during a first-play full-screen open, so this is harmless).
    var playingVideo: Video? {
        vm.isLoading ? vm.history.last : currentVideo
    }

    // MARK: - Imperative dismiss hook

    /// Set by LandscapePresenter's coordinator when a full-screen player is presented.
    /// Fired imperatively by minimize() / stop() to bypass the SwiftUI update-propagation
    /// pause that occurs when the presenting VC's view is removed from the window by
    /// UIKit's .fullScreen presentation style (so updateUIViewController never fires).
    var dismissPlayerAction: (() -> Void)?

    // MARK: - Owned objects

    /// The single PlaybackViewModel for the app. Lives for the app's lifetime.
    public let vm: PlaybackViewModel

    /// The UIView that owns the AVPlayerLayer. Never deallocated; transplanted
    /// between full-screen and mini-player containers via UIView.addSubview.
    let playerHostView: PersistentPlayerHostView

    // MARK: - Init

    public init(api: InnerTubeAPI) {
        let vm = PlaybackViewModel(api: api)
        self.vm = vm
        let hostView = PersistentPlayerHostView()
        hostView.playerLayer.player = vm.player
        self.playerHostView = hostView
    }

    // MARK: - Actions

    /// Load `video` (if not already loaded) and present the full-screen player.
    public func play(video: Video) {
        storeLog.notice("[PlayerStateStore] play — id=\(video.id) currentPresentation=\(String(describing: self.presentation))")
        // Stamp intended_video_id immediately — before load() runs and before the
        // breadcrumb buffer can fill. Comparing with active_video_id in a report
        // reveals prefetch-race / wrong-card-tap scenarios.
        CrashlyticsLogger.setIntendedVideo(id: video.id, title: video.title)
        // Also reload when:
        //   1. Different video — always load
        //   2. No current item — item was cleared by stop() (legacy path)
        //   3. Not playing — item is parked (fix12 park path): stop() keeps the
        //      AVPlayerItem alive but pauses and sets isPlaying=false. On re-tap,
        //      call load() so the park fast-path in PlaybackViewModel resumes it.
        if vm.currentVideoId != video.id || vm.player.currentItem == nil || !vm.isPlaying {
            vm.load(video: video)
        }
        currentVideo = video
        presentation = .fullScreen
        storeLog.notice("[PlayerStateStore] play — presentation set to .fullScreen")
    }

    /// Audio-first tap path: show the compact player immediately while the
    /// coordinator resolves the single progressive/offline byte source.
    func prepareAudioFirst(video: Video) {
        currentVideo = video
        presentation = .miniPlayer
    }

    /// Installs the sparse-cache item without waiting for a download threshold.
    /// The coordinator starts playback immediately so AVPlayer can request the
    /// header, tail index and first media ranges it actually needs.
    func prepareProgressiveAudio(item: AVPlayerItem, video: Video) {
        currentVideo = video
        presentation = .miniPlayer
        vm.loadPreparedAudio(item: item, video: video, startImmediately: false)
    }

    func startPreparedAudioPlayback() {
        vm.startPreparedAudioPlayback()
    }

    /// Resolves and validates a local asset before touching the current player.
    /// This path intentionally never enters the extractor/BotGuard pipeline.
    func validatedLocalAudioItem(for video: Video) async throws -> AVPlayerItem {
        guard let localURL = video.localFileURL else {
            throw NSError(domain: "iPocketTubeOffline", code: 20, userInfo: [
                NSLocalizedDescriptionKey: "Offline item has no local file."
            ])
        }
        let downloadsDirectory = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            // Legacy on-disk directory: changing it would hide existing offline files after install-over.
            .appendingPathComponent("SmartTubeDownloads", isDirectory: true)
            .standardizedFileURL.path
        let standardizedURL = localURL.standardizedFileURL
        guard standardizedURL.path.hasPrefix(downloadsDirectory + "/"),
              FileManager.default.isReadableFile(atPath: standardizedURL.path),
              let values = try? standardizedURL.resourceValues(forKeys: [.fileSizeKey]),
              (values.fileSize ?? 0) > 0 else {
            throw NSError(domain: "iPocketTubeOffline", code: 21, userInfo: [
                NSLocalizedDescriptionKey: "Offline file is missing or unreadable."
            ])
        }
        guard UTType(filenameExtension: standardizedURL.pathExtension)?.conforms(to: .audiovisualContent) == true
                || ["m4a", "mp4", "mov"].contains(standardizedURL.pathExtension.lowercased()) else {
            throw NSError(domain: "iPocketTubeOffline", code: 22, userInfo: [
                NSLocalizedDescriptionKey: "Offline file type is not supported by iOS."
            ])
        }

        let asset = AVURLAsset(url: standardizedURL)
        let isPlayable = try await asset.load(.isPlayable)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard isPlayable, !audioTracks.isEmpty else {
            throw NSError(domain: "iPocketTubeOffline", code: 23, userInfo: [
                NSLocalizedDescriptionKey: "Offline file does not contain playable audio."
            ])
        }
        let item = AVPlayerItem(asset: asset)
        item.audioTimePitchAlgorithm = .spectral
        return item
    }

    func playAudioFirstLocal(video: Video, item: AVPlayerItem) {
        currentVideo = video
        presentation = .miniPlayer
        vm.loadPreparedAudio(item: item, video: video, startImmediately: true)
    }

    /// Collapse the full-screen player to the mini-player bar. Playback continues.
    func minimize() {
        storeLog.notice("[PlayerStateStore] minimize — currentPresentation=\(String(describing: self.presentation))")
        presentation = .miniPlayer
        let action = dismissPlayerAction
        dismissPlayerAction = nil
        storeLog.notice("[PlayerStateStore] minimize — presentation set to .miniPlayer, dismissPlayerAction=\(action != nil)")
        action?()
    }

    /// Expand the mini-player back to full-screen.
    func expand() {
        storeLog.notice("[PlayerStateStore] expand — currentPresentation=\(String(describing: self.presentation))")
        presentation = .fullScreen
        storeLog.notice("[PlayerStateStore] expand — presentation set to .fullScreen")
    }

    /// Stop playback completely and hide the player UI.
    func stop() {
        storeLog.notice("[PlayerStateStore] stop — currentPresentation=\(String(describing: self.presentation))")
        vm.stop()
        currentVideo = nil
        presentation = .hidden
        let action = dismissPlayerAction
        dismissPlayerAction = nil
        storeLog.notice("[PlayerStateStore] stop — presentation set to .hidden, dismissPlayerAction=\(action != nil)")
        action?()
    }
}
#endif
