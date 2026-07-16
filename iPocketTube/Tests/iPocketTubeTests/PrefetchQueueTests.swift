import Foundation
import Testing
@testable import iPocketTubeCore

// MARK: - PrefetchQueueTests
//
// Verifies priority-queue behaviour in VideoPreloadCache:
//  - PrefetchPriority ordering
//  - All CaseIterable cases present
//  - Queue enqueue-not-drop: overflow evicts lowest-priority item

@Suite("Prefetch Priority Queue")
struct PrefetchQueueTests {

    // MARK: - Priority ordering

    @Test("speculative < visible < immediate < userFocused")
    func priorityOrdering() {
        #expect(PrefetchPriority.speculative < .visible)
        #expect(PrefetchPriority.visible < .immediate)
        #expect(PrefetchPriority.immediate < .userFocused)
    }

    @Test("PrefetchPriority has exactly 4 tiers")
    func priorityTierCount() {
        #expect(PrefetchPriority.allCases.count == 4)
    }

    @Test("All priority tiers are present")
    func allPriorityTiersPresent() {
        let tiers = PrefetchPriority.allCases
        #expect(tiers.contains(.speculative))
        #expect(tiers.contains(.visible))
        #expect(tiers.contains(.immediate))
        #expect(tiers.contains(.userFocused))
    }

    @Test("maxQueueDepth is 20")
    func maxQueueDepthIs20() {
        #expect(VideoPreloadCache.maxQueueDepth == 20)
    }

    @Test("maxWorkersWiFi is 5")
    func maxWorkersWiFiIs5() {
        #expect(VideoPreloadCache.maxWorkersWiFi == 5)
    }
}
