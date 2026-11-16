import Foundation
import Testing
@testable import iPocketTubeCore

@Suite("Weak-network stall recovery")
struct StallRecoveryPolicyTests {
    private func decide(
        network: Bool = true, sinceGrowth: TimeInterval = 20, sinceNudge: TimeInterval = 20,
        nudges: Int = 0, stalled: TimeInterval = 20
    ) -> StallRecoveryAction {
        StallRecoveryPolicy.decide(
            networkAvailable: network, secondsSinceBufferGrowth: sinceGrowth,
            secondsSinceLastNudge: sinceNudge, nudges: nudges, secondsStalled: stalled
        )
    }

    @Test func offlineNeverSeeksOrReloads() {
        #expect(decide(network: false, nudges: 5, stalled: 600) == .wait)
    }

    @Test func slowButFlowingDataIsLeftAlone() {
        #expect(decide(sinceGrowth: 3, nudges: 5, stalled: 600) == .wait)
    }

    @Test func stuckLiveConnectionIsNudgedThenReloaded() {
        #expect(decide(nudges: 0) == .nudge)
        #expect(decide(sinceNudge: 4, nudges: 1) == .wait)
        #expect(decide(nudges: 1) == .nudge)
        #expect(decide(nudges: 2, stalled: 20) == .wait)
        #expect(decide(nudges: 2, stalled: 31) == .escalate)
    }

    @Test func bufferTargetsAreMinutesAhead() {
        #expect(PlaybackBufferPolicy.steadyForwardBuffer(audioOnly: false) >= 120)
        #expect(PlaybackBufferPolicy.steadyForwardBuffer(audioOnly: true) > PlaybackBufferPolicy.videoForwardBuffer)
    }
}
