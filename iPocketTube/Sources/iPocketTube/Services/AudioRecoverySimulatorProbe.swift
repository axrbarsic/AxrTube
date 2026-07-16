#if DEBUG && os(iOS)
import AVFoundation
import Foundation
import iPocketTubeCore

/// Existing-app debug launch probe used when the package test target is not part
/// of the iOS Xcode test plan. It is inert unless explicitly launched in Simulator
/// with `--audio-recovery-probe`; it never runs on a physical device.
@MainActor
public enum AudioRecoverySimulatorProbe {
    public static func runIfRequested() {
        let process = ProcessInfo.processInfo
        guard process.arguments.contains("--audio-recovery-probe") else { return }
        #if targetEnvironment(simulator)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            await run()
        }
        #endif
    }

    private static func run() async {
        var pureStatePassed = true
        var state = AudioInterruptionStateMachine()
        for cycle in 0..<20 {
            pureStatePassed = pureStatePassed
                && state.began(wasPlaying: true) == .pauseAndYield
                && state.began(wasPlaying: false) == .ignore
            let expected: AudioInterruptionStateMachine.Action = cycle.isMultiple(of: 2)
                ? .rebuildGraphAndResume
                : .stayPaused
            pureStatePassed = pureStatePassed
                && state.ended(shouldResume: cycle.isMultiple(of: 2)) == expected
                && state.ended(shouldResume: true) == .ignore
                && state.routeBecameUnavailable() == .pauseAndYield
                && state.routeBecameAvailable() == .stayPaused
                && state.mediaServicesLost(wasPlaying: true) == .pauseAndYield
                && state.mediaServicesReset() == .rebuildGraphAndStayPaused
                && state.enteredBackground(playbackAllowed: true, wasPlaying: true) == .ignore
                && state.enteredForeground() == .ignore
        }

        let vm = PlaybackViewModel()
        let inertURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ipockettube-audio-probe.m4a")
        vm.player.replaceCurrentItem(with: AVPlayerItem(url: inertURL))
        vm.isPlaying = true
        let startingResumeCount = vm.audioInterruptionResumeCount

        postInterruption(.began)
        let beganPassed = await waitUntil {
            vm.isHandlingAudioInterruption
                && vm.wasPlayingBeforeInterruption
                && !vm.isPlaying
                && vm.player.rate == 0
        }

        postInterruption(.ended, options: .shouldResume)
        let endedPassed = await waitUntil {
            !vm.isHandlingAudioInterruption
                && vm.audioInterruptionResumeCount == startingResumeCount + 1
        }

        // Duplicate ended must not produce a second recovery.
        postInterruption(.ended, options: .shouldResume)
        try? await Task.sleep(for: .milliseconds(100))
        let duplicatePassed = vm.audioInterruptionResumeCount == startingResumeCount + 1

        vm.isPlaying = true
        postInterruption(.began)
        _ = await waitUntil { vm.isHandlingAudioInterruption }
        vm.performUserPause(reason: "simulator probe manual pause")
        postInterruption(.ended, options: .shouldResume)
        try? await Task.sleep(for: .milliseconds(150))
        let manualPausePassed = vm.audioInterruptionResumeCount == startingResumeCount + 1
            && !vm.isPlaying

        NotificationCenter.default.post(
            name: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            userInfo: [
                AVAudioSessionRouteChangeReasonKey:
                    AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue
            ]
        )
        NotificationCenter.default.post(
            name: AVAudioSession.mediaServicesWereLostNotification,
            object: AVAudioSession.sharedInstance()
        )
        NotificationCenter.default.post(
            name: AVAudioSession.mediaServicesWereResetNotification,
            object: AVAudioSession.sharedInstance()
        )
        vm.handleBackground()
        vm.handleForeground()
        try? await Task.sleep(for: .milliseconds(150))

        let passed = pureStatePassed && beganPassed && endedPassed
            && duplicatePassed && manualPausePassed
        let decision = "pure=\(pureStatePassed) began=\(beganPassed) ended=\(endedPassed) duplicate=\(duplicatePassed) manual=\(manualPausePassed)"
        AudioDiagnostics.shared.record(
            source: "simulator-probe",
            event: passed ? "probe.pass" : "probe.fail",
            decision: decision,
            player: vm.player,
            recoveryGeneration: vm.audioInterruptionGeneration
        )
        print("IPOCKETTUBE_AUDIO_RECOVERY_PROBE_\(passed ? "PASS" : "FAIL") \(decision)")
    }

    private static func postInterruption(
        _ type: AVAudioSession.InterruptionType,
        options: AVAudioSession.InterruptionOptions = []
    ) {
        NotificationCenter.default.post(
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            userInfo: [
                AVAudioSessionInterruptionTypeKey: type.rawValue,
                AVAudioSessionInterruptionOptionKey: options.rawValue,
                AVAudioSessionInterruptionReasonKey:
                    AVAudioSession.InterruptionReason.default.rawValue,
                AVAudioSessionInterruptionWasSuspendedKey: false,
            ]
        )
    }

    private static func waitUntil(
        attempts: Int = 100,
        condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        for _ in 0..<attempts {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }
}
#endif
