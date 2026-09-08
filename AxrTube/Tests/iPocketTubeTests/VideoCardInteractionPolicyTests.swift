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

    @Test("Playback intent stays inside the card")
    func playbackUsesInlinePlayer() {
        #expect(VideoCardInteractionPolicy.presentation(for: .playback) == .inlinePlayer)
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

    @Test("First inline play requests offline storage")
    func inlinePlayRequestsOfflineStorage() {
        #expect(VideoCardOfflineSavePolicy.shouldRequestDownload(
            existingStatus: nil,
            downloadServiceIsActive: false
        ))
        #expect(VideoCardOfflineSavePolicy.shouldRequestDownload(
            existingStatus: nil,
            downloadServiceIsActive: true
        ))
    }

    @Test("Inline transport taps do not duplicate offline work")
    func inlineTransportDoesNotDuplicateDownload() {
        #expect(!VideoCardOfflineSavePolicy.shouldRequestDownload(
            existingStatus: .downloading,
            downloadServiceIsActive: true
        ))
        #expect(!VideoCardOfflineSavePolicy.shouldRequestDownload(
            existingStatus: .completed,
            downloadServiceIsActive: false
        ))
    }
}
