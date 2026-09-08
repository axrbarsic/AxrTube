import Foundation
import Testing
@testable import iPocketTubeCore

@MainActor struct FeedLanguageGateTests {
    @Test func onlyVerifiedRussianIDsArePublished() async {
        let prefix = UUID().uuidString
        let ru = prefix + "ru", en = prefix + "en", unknown = prefix + "unknown"
        _ = await VideoLanguageEvidenceCache.shared.evidence(for: ru) { .init(defaultAudioLanguage: "ru") }
        _ = await VideoLanguageEvidenceCache.shared.evidence(for: en) { .init(defaultAudioLanguage: "en") }
        _ = await VideoLanguageEvidenceCache.shared.evidence(for: unknown) { .init() }
        let gate = FeedLanguageGate()
        #expect(gate.approvedIDs.isEmpty)
        await gate.check([ru, en, unknown, ru], api: MockInnerTubeAPI())
        #expect(gate.approvedIDs == [ru])
        #expect(!gate.isChecking)
    }
}
