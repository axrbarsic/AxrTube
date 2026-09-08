import AVFoundation
import Foundation
import Testing
@testable import iPocketTube
@testable import iPocketTubeCore

@Suite("Installed item timeline") @MainActor
struct PlaybackItemTimelineTests {
    @Test func localMediaPublishesDurationWithoutNetworkMetadataOrPlayerView() async throws {
        let fixture = try #require(Bundle.module.url(forResource: "progressive-audio", withExtension: "m4a"))
        let vm = PlaybackViewModel()
        let item = AVPlayerItem(url: fixture)
        vm.player.replaceCurrentItem(with: item)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while vm.duration == 0 && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(item.status != .failed)
        #expect(vm.duration > 0)
        #expect(abs(vm.duration - item.duration.seconds) < 0.01)
        #expect(vm.player.rate == 0)
        vm.player.replaceCurrentItem(with: nil)
    }

    @Test func replacedItemCannotPublishLateDuration() {
        let vm = PlaybackViewModel()
        let stale = AVPlayerItem(asset: AVMutableComposition())
        let current = AVPlayerItem(asset: AVMutableComposition())
        vm.player.replaceCurrentItem(with: current)
        vm.publishItemDuration(30, from: current)
        vm.publishItemDuration(900, from: stale)
        #expect(vm.duration == 30)
        vm.publishItemDuration(.infinity, from: current)
        vm.publishItemDuration(.nan, from: current)
        vm.publishItemDuration(0, from: current)
        #expect(vm.duration == 30)
        vm.player.replaceCurrentItem(with: nil)
    }

    @Test func unknownDurationDoesNotZeroObservedPosition() {
        #expect(PlaybackPositionPolicy.displayedPosition(observed: 42, duration: 0) == 42)
        #expect(PlaybackPositionPolicy.displayedPosition(observed: 42, duration: .nan) == 42)
        #expect(PlaybackPositionPolicy.displayedPosition(observed: 42, duration: .infinity) == 42)
        #expect(PlaybackPositionPolicy.displayedPosition(observed: 42, duration: 30) == 30)
        #expect(PlaybackPositionPolicy.displayedPosition(observed: .nan, duration: 30) == 0)
        #expect(PlaybackPositionPolicy.displayedPosition(observed: -4, duration: 30) == 0)
    }
}
