import AVFoundation
import Foundation
import Testing
@testable import iPocketTube
@testable import iPocketTubeCore

@Suite("Installed item timeline") @MainActor
struct PlaybackItemTimelineTests {
    @Test func localSwitchClearsQualityWaitAndSupportsScrubbing() async throws {
        let fixture = try #require(Bundle.module.url(forResource: "progressive-audio", withExtension: "m4a"))
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SmartTubeDownloads")
            .appendingPathComponent("switch-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let local = directory.appendingPathComponent("fixture.m4a")
        try FileManager.default.copyItem(at: fixture, to: local)
        let vm = PlaybackViewModel()
        vm.settings.historyState = .disabled
        vm.player.isMuted = true
        defer {
            vm.loadTask?.cancel()
            vm.player.pause()
            vm.player.replaceCurrentItem(with: nil)
            try? FileManager.default.removeItem(at: directory)
        }
        var first = Video(id: "local-switch-a", title: "A", channelTitle: "Fixture")
        first.localFileURL = local
        first.localMediaKind = .audio
        var second = Video(id: "local-switch-b", title: "B", channelTitle: "Fixture")
        second.localFileURL = local
        second.localMediaKind = .audio

        vm.load(video: first)
        try await waitUntil { vm.duration > 0 && vm.currentTime > 0.1 }
        vm.isQualityChangePending = true
        vm.load(video: second)
        #expect(!vm.isQualityChangePending)
        try await waitUntil { vm.duration > 0 && vm.currentTime > 0.1 }
        let current = try #require(vm.player.currentItem)
        await vm.loadAsync(video: first)
        #expect(vm.player.currentItem === current)
        #expect(vm.currentVideoId == second.id)

        vm.beginScrubbing()
        vm.updateScrub(to: 20)
        vm.commitScrub()
        try await waitUntil { vm.player.currentTime().seconds >= 19.9 && vm.currentTime >= 19.9 }
        #expect(!vm.isScrubbing)
        #expect(vm.duration > 50)
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !predicate() && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(predicate())
    }

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
