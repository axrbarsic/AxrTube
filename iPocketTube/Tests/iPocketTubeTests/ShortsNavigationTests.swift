import Foundation
import Testing
@testable import iPocketTubeCore

// MARK: - ShortsNavigationTests
//
// Unit tests for ShortsNavigation.targetIndex — the pure function that drives
// swipe-up / swipe-down navigation in ShortsPlayerView.
//
// Each test fixes one observed failure scenario so regressions are caught
// before the gesture hits the SwiftUI layer.

@Suite("Shorts Navigation")
struct ShortsNavigationTests {

    // MARK: - Swipe up → next short

    @Test("Swipe up from middle advances to next index")
    func swipeUpAdvances() {
        let result = ShortsNavigation.targetIndex(
            vertical: -80, horizontal: 5, current: 1, count: 3
        )
        #expect(result == 2)
    }

    @Test("Swipe up from first index advances to second")
    func swipeUpFromFirst() {
        let result = ShortsNavigation.targetIndex(
            vertical: -80, horizontal: 5, current: 0, count: 3
        )
        #expect(result == 1)
    }

    @Test("Swipe up at last index returns nil — no overflow")
    func swipeUpAtLastReturnsNil() {
        let result = ShortsNavigation.targetIndex(
            vertical: -80, horizontal: 5, current: 2, count: 3
        )
        #expect(result == nil)
    }

    // MARK: - Swipe down → previous short

    @Test("Swipe down from middle goes to previous index")
    func swipeDownGoesToPrevious() {
        let result = ShortsNavigation.targetIndex(
            vertical: 80, horizontal: 5, current: 1, count: 3
        )
        #expect(result == 0)
    }

    @Test("Swipe down from last index goes to second-to-last")
    func swipeDownFromLast() {
        let result = ShortsNavigation.targetIndex(
            vertical: 80, horizontal: 5, current: 2, count: 3
        )
        #expect(result == 1)
    }

    @Test("Swipe down at first index returns nil — no underflow")
    func swipeDownAtFirstReturnsNil() {
        let result = ShortsNavigation.targetIndex(
            vertical: 80, horizontal: 5, current: 0, count: 3
        )
        #expect(result == nil)
    }

    // MARK: - Horizontal swipes are ignored

    @Test("Predominantly horizontal swipe returns nil")
    func horizontalSwipeIgnored() {
        let result = ShortsNavigation.targetIndex(
            vertical: -50, horizontal: 100, current: 1, count: 3
        )
        #expect(result == nil)
    }

    @Test("Diagonal swipe with equal vertical and horizontal returns nil")
    func diagonalSwipeIgnored() {
        let result = ShortsNavigation.targetIndex(
            vertical: -60, horizontal: 60, current: 1, count: 3
        )
        #expect(result == nil)
    }

    // MARK: - Sub-threshold swipes are ignored

    @Test("Vertical swipe shorter than 40pt threshold returns nil")
    func subThresholdUpIgnored() {
        let result = ShortsNavigation.targetIndex(
            vertical: -30, horizontal: 5, current: 1, count: 3
        )
        #expect(result == nil)
    }

    @Test("Vertical swipe exactly at -40pt boundary is ignored (exclusive)")
    func exactNegativeThresholdIgnored() {
        let result = ShortsNavigation.targetIndex(
            vertical: -40, horizontal: 5, current: 1, count: 3
        )
        #expect(result == nil)
    }

    @Test("Vertical swipe exactly at +40pt boundary is ignored (exclusive)")
    func exactPositiveThresholdIgnored() {
        let result = ShortsNavigation.targetIndex(
            vertical: 40, horizontal: 5, current: 1, count: 3
        )
        #expect(result == nil)
    }

    // MARK: - Single video list

    @Test("Single video — swipe up returns nil")
    func singleVideoSwipeUp() {
        let result = ShortsNavigation.targetIndex(
            vertical: -80, horizontal: 5, current: 0, count: 1
        )
        #expect(result == nil)
    }

    @Test("Single video — swipe down returns nil")
    func singleVideoSwipeDown() {
        let result = ShortsNavigation.targetIndex(
            vertical: 80, horizontal: 5, current: 0, count: 1
        )
        #expect(result == nil)
    }
}
