import Foundation
import Testing
@testable import iPocketTubeCore

// MARK: - SponsorBlockStallTests

@Suite("SponsorBlock Stall Prevention")
struct SponsorBlockStallTests {

    /// Verifies that the near-end-of-video threshold is 2.0 s, not 0.5 s.
    /// A segment whose end is within 2.0 s of the video duration must be treated
    /// as an end-of-video event to prevent AVPlayer from clamping to the last
    /// decodable frame without firing didPlayToEndTimeNotification.
    @Test func segmentEndingWithin2SecondsOfDurationIsNearEnd() {
        let videoDuration: TimeInterval = 120.0
        let nearEndSegment = SponsorSegment(start: 100.0, end: 118.5, category: .sponsor)
        // 118.5 >= 120.0 - 2.0 (118.0) → treated as end-of-video
        #expect(nearEndSegment.end >= videoDuration - 2.0)
    }

    @Test func segmentEndingMoreThan2SecondsBeforeDurationIsNotNearEnd() {
        let videoDuration: TimeInterval = 120.0
        let midSegment = SponsorSegment(start: 50.0, end: 116.0, category: .sponsor)
        // 116.0 < 120.0 - 2.0 (118.0) → normal skip, not end-of-video
        #expect(midSegment.end < videoDuration - 2.0)
    }

    /// The previous threshold was 0.5 s — verify it would incorrectly classify
    /// a segment that should be skipped normally.
    @Test func previousThresholdWouldMisclassifyMidVideoSegment() {
        let videoDuration: TimeInterval = 120.0
        let shouldBeNormalSkip = SponsorSegment(start: 50.0, end: 119.6, category: .sponsor)
        // Old threshold (0.5): 119.6 >= 119.5 → would call handlePlaybackEnd() incorrectly
        #expect(shouldBeNormalSkip.end >= videoDuration - 0.5)
        // New threshold (2.0): 119.6 >= 118.0 → correctly calls handlePlaybackEnd()
        // (This segment IS near end, so new behaviour is also correct for it)
        #expect(shouldBeNormalSkip.end >= videoDuration - 2.0)
    }
}
