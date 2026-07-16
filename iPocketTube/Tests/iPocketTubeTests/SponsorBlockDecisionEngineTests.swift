import Testing
@testable import iPocketTubeCore

// MARK: - SponsorBlockDecisionEngine unit tests
//
// Covers the pure decision logic shared by SponsorBlockSkipManager (standard
// player) and TOSPlayerViewModel+SponsorBlock (TOS player) — see
// arch-plan-2-sponsorblock-decision-engine.md.

@Suite("SponsorBlockDecisionEngine")
struct SponsorBlockDecisionEngineTests {

    private func settings(_ actions: [SponsorSegment.Category: AppSettings.SponsorBlockAction], enabled: Bool = true) -> AppSettings {
        var s = AppSettings()
        s.sponsorBlockEnabled = enabled
        s.sponsorBlockActions = actions
        return s
    }

    @Test("disabled SponsorBlock always clears toast")
    func disabledClearsToast() {
        let seg = SponsorSegment(start: 0, end: 10, category: .sponsor)
        let result = SponsorBlockDecisionEngine.decide(
            at: 5, segments: [seg], settings: settings([.sponsor: .skip], enabled: false),
            isSkipInProgress: false, duration: 100
        )
        #expect(result == .clearToast)
    }

    @Test("no matching segment clears toast")
    func noSegmentClearsToast() {
        let seg = SponsorSegment(start: 0, end: 10, category: .sponsor)
        let result = SponsorBlockDecisionEngine.decide(
            at: 20, segments: [seg], settings: settings([.sponsor: .skip]),
            isSkipInProgress: false, duration: 100
        )
        #expect(result == .clearToast)
    }

    @Test(".skip action mid-video skips to segment end")
    func skipMidVideo() {
        let seg = SponsorSegment(start: 10, end: 30, category: .sponsor)
        let result = SponsorBlockDecisionEngine.decide(
            at: 15, segments: [seg], settings: settings([.sponsor: .skip]),
            isSkipInProgress: false, duration: 100
        )
        #expect(result == .skip(to: 30, segment: seg))
    }

    @Test("skip already in progress returns none")
    func skipInProgressReturnsNone() {
        let seg = SponsorSegment(start: 10, end: 30, category: .sponsor)
        let result = SponsorBlockDecisionEngine.decide(
            at: 15, segments: [seg], settings: settings([.sponsor: .skip]),
            isSkipInProgress: true, duration: 100
        )
        #expect(result == .none)
    }

    @Test("segment ending within 2s of duration skips to playback end")
    func nearEndSkipsToPlaybackEnd() {
        let seg = SponsorSegment(start: 25, end: 29.5, category: .sponsor)
        let result = SponsorBlockDecisionEngine.decide(
            at: 26, segments: [seg], settings: settings([.sponsor: .skip]),
            isSkipInProgress: false, duration: 30
        )
        #expect(result == .skipToPlaybackEnd(segment: seg))
    }

    @Test("duration <= 0 disables the end-of-video special case")
    func unknownDurationDisablesNearEndCase() {
        let seg = SponsorSegment(start: 25, end: 29.5, category: .sponsor)
        let result = SponsorBlockDecisionEngine.decide(
            at: 26, segments: [seg], settings: settings([.sponsor: .skip]),
            isSkipInProgress: false, duration: 0
        )
        #expect(result == .skip(to: 29.5, segment: seg))
    }

    @Test(".showToast action surfaces the segment")
    func showToastAction() {
        let seg = SponsorSegment(start: 5, end: 15, category: .interaction)
        let result = SponsorBlockDecisionEngine.decide(
            at: 8, segments: [seg], settings: settings([.interaction: .showToast]),
            isSkipInProgress: false, duration: 100
        )
        #expect(result == .showToast(seg))
    }

    @Test(".nothing action clears toast")
    func nothingActionClearsToast() {
        let seg = SponsorSegment(start: 5, end: 15, category: .outro)
        let result = SponsorBlockDecisionEngine.decide(
            at: 8, segments: [seg], settings: settings([.outro: .nothing]),
            isSkipInProgress: false, duration: 100
        )
        #expect(result == .clearToast)
    }
}
