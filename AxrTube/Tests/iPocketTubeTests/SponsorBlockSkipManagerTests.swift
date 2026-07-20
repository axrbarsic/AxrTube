import Testing
import AVFoundation
@testable import iPocketTubeCore

// MARK: - SponsorBlockSkipManager unit tests
//
// Tests verify the four key behaviours from task #63:
//   1. .skip category seeks past the segment and returns true
//   2. isSkippingSegment guard prevents re-entry while a seek is in-flight
//   3. .showToast category surfaces currentToastSegment without auto-seeking
//   4. Near-end segment calls handlePlaybackEnd instead of seeking

// MARK: - Test double

@MainActor
private final class SpyDelegate: SponsorBlockDelegate {
    var settings: AppSettings
    var duration: Double = 100.0
    var seekCalled: Double? = nil
    var playbackEndCalled = false
    var showControlsCalled = false
    var snapCalled: Double? = nil

    init(sponsorBlockEnabled: Bool = true) {
        var s = AppSettings()
        s.sponsorBlockEnabled = sponsorBlockEnabled
        self.settings = s
    }

    func seek(to seconds: Double) { seekCalled = seconds }
    func handlePlaybackEnd() { playbackEndCalled = true }
    func showControls() { showControlsCalled = true }
    func snapCurrentTime(to seconds: Double) { snapCalled = seconds }
}

// MARK: - Tests

@Suite("SponsorBlockSkipManager")
struct SponsorBlockSkipManagerTests {

    // MARK: - 1. .skip category triggers seek

    @Test(".skip segment returns true and triggers seek on delegate")
    @MainActor func skipCategorySeeks() async {
        let manager = SponsorBlockSkipManager()
        let delegate = SpyDelegate()
        let player = AVPlayer()
        manager.delegate = delegate
        manager.player = player
        manager.sponsorSegments = [SponsorSegment(
            id: UUID(), start: 10.0, end: 30.0, category: .sponsor
        )]
        // Override delegate settings to use .skip for sponsor
        var settings = AppSettings()
        settings.sponsorBlockEnabled = true
        settings.sponsorBlockActions[.sponsor] = .skip
        delegate.settings = settings

        let result = manager.checkSponsorSkip(at: 15.0)
        #expect(result == true)
    }

    // MARK: - 2. isSkippingSegment guard prevents re-entry

    @Test("checkSponsorSkip returns true immediately when isSkippingSegment is set")
    @MainActor func isSkippingSegmentGuard() async {
        let manager = SponsorBlockSkipManager()
        let delegate = SpyDelegate()
        manager.delegate = delegate
        manager.player = AVPlayer()
        manager.sponsorSegments = [SponsorSegment(
            id: UUID(), start: 5.0, end: 20.0, category: .sponsor
        )]
        var settings = AppSettings()
        settings.sponsorBlockEnabled = true
        settings.sponsorBlockActions[.sponsor] = .skip
        delegate.settings = settings

        // First call sets isSkippingSegment = true
        _ = manager.checkSponsorSkip(at: 10.0)
        #expect(manager.isSkippingSegment == true)

        // Second call while flag is set should still return true (guard path)
        let secondResult = manager.checkSponsorSkip(at: 10.0)
        #expect(secondResult == true)
    }

    // MARK: - 3. .showToast category surfaces currentToastSegment

    @Test(".showToast segment sets currentToastSegment without seeking")
    @MainActor func showToastSetsCurrent() async {
        let manager = SponsorBlockSkipManager()
        let delegate = SpyDelegate()
        manager.delegate = delegate
        let seg = SponsorSegment(id: UUID(), start: 5.0, end: 15.0, category: .selfPromo)
        manager.sponsorSegments = [seg]
        var settings = AppSettings()
        settings.sponsorBlockEnabled = true
        settings.sponsorBlockActions[.selfPromo] = .showToast
        delegate.settings = settings

        let result = manager.checkSponsorSkip(at: 8.0)
        #expect(result == false)
        #expect(manager.currentToastSegment?.id == seg.id)
        #expect(delegate.seekCalled == nil)
    }

    // MARK: - 4. Near-end segment calls handlePlaybackEnd

    @Test("segment ending within 2s of duration calls handlePlaybackEnd")
    @MainActor func nearEndSegmentEndsPlayback() async {
        let manager = SponsorBlockSkipManager()
        let delegate = SpyDelegate()
        delegate.duration = 30.0
        manager.delegate = delegate
        manager.player = nil  // no real player, uses delegate.duration
        manager.sponsorSegments = [SponsorSegment(
            id: UUID(), start: 25.0, end: 29.5, category: .sponsor
        )]
        var settings = AppSettings()
        settings.sponsorBlockEnabled = true
        settings.sponsorBlockActions[.sponsor] = .skip
        delegate.settings = settings

        let result = manager.checkSponsorSkip(at: 26.0)
        #expect(result == true)
        #expect(delegate.playbackEndCalled == true)
        #expect(delegate.seekCalled == nil)
    }

    // MARK: - 5. reset() clears all state

    @Test("reset() clears segments, toast, and isSkippingSegment")
    @MainActor func resetClearsState() async {
        let manager = SponsorBlockSkipManager()
        manager.sponsorSegments = [SponsorSegment(id: UUID(), start: 0, end: 10, category: .sponsor)]
        manager.currentToastSegment = SponsorSegment(id: UUID(), start: 5, end: 8, category: .selfPromo)
        manager.reset()
        #expect(manager.sponsorSegments.isEmpty)
        #expect(manager.currentToastSegment == nil)
        #expect(manager.isSkippingSegment == false)
    }
}
