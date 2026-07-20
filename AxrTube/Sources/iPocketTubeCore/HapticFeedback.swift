import Foundation

#if canImport(UIKit)
import UIKit
#endif

/// Stable semantic inventory for user-initiated actions. UI surfaces describe intent;
/// the platform owner below is the only place that chooses concrete generators.
public enum iPocketTubeHapticAction: String, CaseIterable, Sendable {
    case tabSelection
    case segmentSelection
    case searchSubmit
    case searchClear
    case searchSuggestionSelection
    case searchHistorySelection
    case searchHistoryDelete
    case filterPresentation
    case filterChange
    case filterApply
    case primaryAction
    case contentSelection
    case channelSelection
    case playlistSelection
    case downloadSelection
    case playbackTransport
    case seekCommit
    case downloadRetry
    case downloadPauseResume
    case downloadDelete
    case downloadClear
    case settingsToggle
    case settingsPicker
    case settingsReset
    case signIn
    case signOut
    case share
    case safariOpen
    case edrPrimary
    case operationSucceeded
    case operationWarning
    case operationFailed
}

public enum iPocketTubeHapticFeedback: String, Equatable, Sendable {
    case selection
    case lightImpact
    case mediumImpact
    case rigidImpact
    case success
    case warning
    case error
}

public enum iPocketTubeHapticPolicy {
    public static func feedback(for action: iPocketTubeHapticAction) -> iPocketTubeHapticFeedback {
        switch action {
        case .tabSelection, .segmentSelection, .searchClear, .searchSuggestionSelection,
             .searchHistorySelection, .filterChange, .settingsToggle, .settingsPicker:
            return .selection
        case .filterPresentation, .contentSelection, .channelSelection,
             .playlistSelection, .downloadSelection, .share, .safariOpen:
            return .lightImpact
        case .searchSubmit, .filterApply, .primaryAction, .playbackTransport, .seekCommit,
             .downloadPauseResume, .signIn, .edrPrimary:
            return .mediumImpact
        case .downloadRetry, .settingsReset, .operationWarning:
            return .warning
        case .searchHistoryDelete, .downloadDelete, .downloadClear, .signOut:
            return .rigidImpact
        case .operationSucceeded:
            return .success
        case .operationFailed:
            return .error
        }
    }
}

/// The sole production owner of app-generated haptics. It is deliberately a
/// no-op outside iOS and never schedules or delays the associated UI action.
@MainActor
public final class iPocketTubeHaptics {
    public static let shared = iPocketTubeHaptics()

    private var lastAction: iPocketTubeHapticAction?
    private var lastEmissionUptime: TimeInterval = 0

    #if os(iOS) && canImport(UIKit)
    private let selectionGenerator = UISelectionFeedbackGenerator()
    private let lightGenerator = UIImpactFeedbackGenerator(style: .light)
    private let mediumGenerator = UIImpactFeedbackGenerator(style: .medium)
    private let rigidGenerator = UIImpactFeedbackGenerator(style: .rigid)
    private let notificationGenerator = UINotificationFeedbackGenerator()
    #endif

    private init() {}

    public func perform(_ action: iPocketTubeHapticAction) {
        #if os(iOS) && canImport(UIKit)
        let now = ProcessInfo.processInfo.systemUptime
        // Prevent the same physical tap being emitted twice by nested custom
        // controls. The window is far below deliberate rapid interaction.
        guard lastAction != action || now - lastEmissionUptime >= 0.035 else { return }
        lastAction = action
        lastEmissionUptime = now

        switch iPocketTubeHapticPolicy.feedback(for: action) {
        case .selection:
            selectionGenerator.selectionChanged()
            selectionGenerator.prepare()
        case .lightImpact:
            lightGenerator.impactOccurred(intensity: 0.65)
            lightGenerator.prepare()
        case .mediumImpact:
            mediumGenerator.impactOccurred(intensity: 0.85)
            mediumGenerator.prepare()
        case .rigidImpact:
            rigidGenerator.impactOccurred(intensity: 0.92)
            rigidGenerator.prepare()
        case .success:
            notificationGenerator.notificationOccurred(.success)
            notificationGenerator.prepare()
        case .warning:
            notificationGenerator.notificationOccurred(.warning)
            notificationGenerator.prepare()
        case .error:
            notificationGenerator.notificationOccurred(.error)
            notificationGenerator.prepare()
        }
        #endif
    }
}
