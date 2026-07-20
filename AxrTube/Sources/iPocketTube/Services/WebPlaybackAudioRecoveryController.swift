#if os(iOS)
import AVFoundation
import Foundation
import iPocketTubeCore

@MainActor
protocol WebPlaybackAudioRecoveryDelegate: AnyObject {
    var webAudioPlaybackIsActive: Bool { get }
    var webAudioPlaybackCanOwnSession: Bool { get }
    func pauseWebPlaybackForSystemAudioEvent()
    func resumeWebPlaybackAfterSystemAudioEvent()
}

/// Applies the native playback-session policy to WKWebView-backed media. WebKit
/// owns the concrete audio graph, so recovery cannot replace an AVPlayerItem;
/// instead it serialises pause/resume intent around the same tested state machine
/// and reasserts the complete AVAudioSession contract before the single resume.
@MainActor
final class WebPlaybackAudioRecoveryController {
    weak var delegate: (any WebPlaybackAudioRecoveryDelegate)?

    private let source: String
    private var state = AudioInterruptionStateMachine()
    private var hasStarted = false
    nonisolated(unsafe) private var observerTokens: [NSObjectProtocol] = []

    init(source: String) {
        self.source = source
    }

    deinit {
        for token in observerTokens {
            NotificationCenter.default.removeObserver(token)
        }
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()

        observerTokens.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: session,
            queue: nil
        ) { [weak self] notification in
            let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let rawOptions = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let rawReason = notification.userInfo?[AVAudioSessionInterruptionReasonKey] as? UInt
            let wasSuspended = (notification.userInfo?[AVAudioSessionInterruptionWasSuspendedKey] as? NSNumber)?.boolValue ?? false
            Task { @MainActor [weak self] in
                self?.handleInterruption(
                    rawType: rawType,
                    rawOptions: rawOptions,
                    rawReason: rawReason,
                    wasSuspended: wasSuspended
                )
            }
        })
        observerTokens.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: session,
            queue: nil
        ) { [weak self] notification in
            let rawReason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            Task { @MainActor [weak self] in self?.handleRouteChange(rawReason: rawReason) }
        })
        observerTokens.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereLostNotification,
            object: session,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleMediaServicesLost() }
        })
        observerTokens.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: session,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleMediaServicesReset() }
        })

        AudioDiagnostics.shared.record(
            source: source,
            event: "observers.started",
            decision: "web playback"
        )
    }

    /// Returns false while another session or media-services outage owns the
    /// route. This prevents a UI/remote command from fighting microphone input.
    func userRequestedPlay(reason: String) -> Bool {
        start()
        guard delegate?.webAudioPlaybackCanOwnSession == true,
              !state.mediaServicesAreLost else {
            AudioDiagnostics.shared.record(
                source: source,
                event: "user.play.blocked",
                decision: reason,
                recoveryGeneration: state.generation
            )
            return false
        }
        let wasRecoveringMissingEnded = state.isHandling
        _ = state.userRequestedPlay()
        let activated = PlaybackViewModel.activatePlaybackAudioSession(reason: reason)
        AudioDiagnostics.shared.record(
            source: source,
            event: "user.play.session",
            decision: activated
                ? (wasRecoveringMissingEnded ? "activated after missing ended" : "activated")
                : "activation failed",
            recoveryGeneration: state.generation
        )
        return activated
    }

    func userPaused(reason: String) {
        state.userPaused()
        AudioDiagnostics.shared.record(
            source: source,
            event: "user.pause",
            decision: reason,
            recoveryGeneration: state.generation
        )
    }

    func enteredBackground(playbackAllowed: Bool) {
        let action = state.enteredBackground(
            playbackAllowed: playbackAllowed,
            wasPlaying: delegate?.webAudioPlaybackIsActive == true
        )
        AudioDiagnostics.shared.record(
            source: source,
            event: "lifecycle.background",
            decision: String(describing: action),
            recoveryGeneration: state.generation
        )
        if action == .stayPaused {
            delegate?.pauseWebPlaybackForSystemAudioEvent()
        }
    }

    func enteredForeground() {
        let action = state.enteredForeground()
        AudioDiagnostics.shared.record(
            source: source,
            event: "lifecycle.foreground",
            decision: String(describing: action),
            recoveryGeneration: state.generation
        )
    }

    private func handleInterruption(
        rawType: UInt?,
        rawOptions: UInt,
        rawReason: UInt?,
        wasSuspended: Bool
    ) {
        guard delegate?.webAudioPlaybackCanOwnSession == true,
              let rawType,
              let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return }

        switch type {
        case .began:
            let action = state.began(wasPlaying: delegate?.webAudioPlaybackIsActive == true)
            AudioDiagnostics.shared.record(
                source: source,
                event: "interruption.began",
                decision: String(describing: action),
                interruptionType: rawType,
                interruptionOptions: rawOptions,
                interruptionReason: rawReason,
                interruptionWasSuspended: wasSuspended,
                recoveryGeneration: state.generation
            )
            if action == .pauseAndYield {
                // The system already made the session inactive. Do not call
                // setActive(false); only stop WebKit's playhead immediately.
                delegate?.pauseWebPlaybackForSystemAudioEvent()
            }

        case .ended:
            let shouldResume = AVAudioSession.InterruptionOptions(rawValue: rawOptions)
                .contains(.shouldResume)
            let action = state.ended(shouldResume: shouldResume)
            AudioDiagnostics.shared.record(
                source: source,
                event: "interruption.ended",
                decision: String(describing: action),
                interruptionType: rawType,
                interruptionOptions: rawOptions,
                interruptionReason: rawReason,
                interruptionWasSuspended: wasSuspended,
                recoveryGeneration: state.generation
            )
            guard action == .rebuildGraphAndResume else { return }
            guard state.completePendingResume(generation: state.generation) else { return }
            delegate?.resumeWebPlaybackAfterSystemAudioEvent()

        @unknown default:
            break
        }
    }

    private func handleRouteChange(rawReason: UInt?) {
        guard delegate?.webAudioPlaybackCanOwnSession == true,
              let rawReason,
              let reason = AVAudioSession.RouteChangeReason(rawValue: rawReason) else { return }

        let action: AudioInterruptionStateMachine.Action
        switch reason {
        case .oldDeviceUnavailable, .noSuitableRouteForCategory:
            action = state.routeBecameUnavailable(
                wasPlaying: delegate?.webAudioPlaybackIsActive == true
            )
            delegate?.pauseWebPlaybackForSystemAudioEvent()
        case .newDeviceAvailable, .wakeFromSleep, .routeConfigurationChange:
            action = state.routeBecameAvailable()
        default:
            action = .ignore
        }
        AudioDiagnostics.shared.record(
            source: source,
            event: "route.changed",
            decision: "reason=\(rawReason) action=\(action)",
            recoveryGeneration: state.generation
        )
    }

    private func handleMediaServicesLost() {
        guard delegate?.webAudioPlaybackCanOwnSession == true else { return }
        let action = state.mediaServicesLost(wasPlaying: delegate?.webAudioPlaybackIsActive == true)
        delegate?.pauseWebPlaybackForSystemAudioEvent()
        AudioDiagnostics.shared.record(
            source: source,
            event: "mediaServices.lost",
            decision: String(describing: action),
            recoveryGeneration: state.generation
        )
    }

    private func handleMediaServicesReset() {
        guard delegate?.webAudioPlaybackCanOwnSession == true else { return }
        let action = state.mediaServicesReset()
        let configured = PlaybackViewModel.configurePlaybackAudioSession(
            reason: "\(source) media services reset"
        )
        AudioDiagnostics.shared.record(
            source: source,
            event: "mediaServices.reset",
            decision: "\(action); configured=\(configured)",
            recoveryGeneration: state.generation
        )
        // Apple requires playback to remain paused until a new user action.
    }
}
#endif
