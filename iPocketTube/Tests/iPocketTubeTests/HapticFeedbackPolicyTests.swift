import Testing
@testable import iPocketTubeCore

@Suite("Semantic haptic feedback")
struct HapticFeedbackPolicyTests {
    @Test("Every production action has one feedback decision")
    func completeInventory() {
        let actions = iPocketTubeHapticAction.allCases
        let decisions = actions.map(iPocketTubeHapticPolicy.feedback(for:))

        #expect(actions.count == 32)
        #expect(decisions.count == actions.count)
    }

    @Test("Navigation and value changes stay light")
    func selectionSemantics() {
        for action in [
            iPocketTubeHapticAction.tabSelection,
            .segmentSelection,
            .searchClear,
            .searchSuggestionSelection,
            .filterChange,
            .settingsToggle,
            .settingsPicker,
        ] {
            #expect(iPocketTubeHapticPolicy.feedback(for: action) == .selection)
        }
    }

    @Test("Playback and committed seek are stronger than selection")
    func transportSemantics() {
        #expect(iPocketTubeHapticPolicy.feedback(for: .playbackTransport) == .mediumImpact)
        #expect(iPocketTubeHapticPolicy.feedback(for: .seekCommit) == .mediumImpact)
    }

    @Test("Retry, destructive and completion meanings are distinct")
    func outcomeSemantics() {
        #expect(iPocketTubeHapticPolicy.feedback(for: .downloadRetry) == .warning)
        #expect(iPocketTubeHapticPolicy.feedback(for: .downloadDelete) == .rigidImpact)
        #expect(iPocketTubeHapticPolicy.feedback(for: .downloadClear) == .rigidImpact)
        #expect(iPocketTubeHapticPolicy.feedback(for: .operationSucceeded) == .success)
        #expect(iPocketTubeHapticPolicy.feedback(for: .operationFailed) == .error)
    }

    @Test("Passive rendering, scrolling and progress are not action events")
    func noPassiveEvents() {
        let names = Set(iPocketTubeHapticAction.allCases.map(\.rawValue))
        #expect(!names.contains("render"))
        #expect(!names.contains("scroll"))
        #expect(!names.contains("progress"))
        #expect(!names.contains("sliderDrag"))
    }
}
