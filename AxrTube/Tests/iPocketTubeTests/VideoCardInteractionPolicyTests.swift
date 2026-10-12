import Testing
@testable import iPocketTubeCore

@Suite("Video card intent isolation")
struct VideoCardInteractionPolicyTests {
    @Test("Card surface tap never presents the player")
    func surfaceTapDoesNotPresentPlayer() {
        #expect(VideoCardInteractionPolicy.presentation(for: .surfaceTap) == .none)
    }

    @Test("Download intent never presents the player")
    func downloadDoesNotPresentPlayer() {
        #expect(VideoCardInteractionPolicy.presentation(for: .download) == .none)
    }

    @Test("Playback intent opens the watch page, like YouTube")
    func playbackOpensWatchPage() {
        #expect(VideoCardInteractionPolicy.presentation(for: .playback) == .player)
    }

    @Test("Download state preserves transcript and menu capabilities")
    func downloadPreservesCapabilities() {
        for isDownloading in [false, true] {
            let capabilities = VideoCardInteractionPolicy.capabilities(
                whileDownloading: isDownloading
            )
            #expect(capabilities.contains(.transcript))
            #expect(capabilities.contains(.menuActions))
        }
    }

    @Test("Inline playback requests offline storage only after playback starts")
    func inlinePlayRequestsOfflineStorageAfterPlaybackStarts() {
        #expect(!VideoCardOfflineSavePolicy.shouldRequestDownload(
            existingStatus: nil,
            playbackIsRunning: false
        ))
        #expect(VideoCardOfflineSavePolicy.shouldRequestDownload(
            existingStatus: nil,
            playbackIsRunning: true
        ))
    }

    @Test("Inline transport taps do not duplicate offline work")
    func inlineTransportDoesNotDuplicateDownload() {
        #expect(!VideoCardOfflineSavePolicy.shouldRequestDownload(
            existingStatus: .downloading,
            playbackIsRunning: true
        ))
        #expect(!VideoCardOfflineSavePolicy.shouldRequestDownload(
            existingStatus: .completed,
            playbackIsRunning: true
        ))
    }
}
