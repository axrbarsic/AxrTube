#if os(iOS)
import SwiftUI
import iPocketTubeCore

// MARK: - YouTube watch page layout
//
// Portrait: 16:9 player on top, details and related videos below.
// Landscape (device rotated): the player alone fills the screen.
extension PlayerView {

    var watchLayout: some View {
        GeometryReader { geo in
            let isLandscape = geo.size.width > geo.size.height
            if isLandscape {
                playerContentView(showsOverlays: true)
            } else {
                VStack(spacing: 0) {
                    playerContentView(showsOverlays: false)
                        .frame(height: (geo.size.width * 9 / 16).rounded())
                        .clipped()
                    watchDetails
                }
                .background(YTColor.background)
                // Sheets cover the whole watch page, not just the 16:9 player.
                .overlay { overlayStack }
                .onChange(of: audioDownloadService.lastMessage) { _, message in
                    guard let message else { return }
                    vm.toastMessage = message
                    audioDownloadService.lastMessage = nil
                }
            }
        }
        .background(Color.black.ignoresSafeArea(edges: .top))
    }

    /// Metadata of the item actually playing: the player response once it
    /// matches the selected video, otherwise the tapped card's data.
    var watchVideo: Video {
        let selected = playerState.currentVideo ?? video
        if let info = vm.playerInfo?.video, info.id == selected.id { return info }
        return selected
    }

    private var watchDetails: some View {
        let current = watchVideo
        return YTWatchDetails(
            video: current,
            related: vm.relatedVideos,
            likeStatus: vm.likeStatus,
            isSignedIn: authService.isSignedIn,
            isDownloading: downloadService.state.isActive
                || audioDownloadService.isDownloading(videoID: current.id),
            actions: .init(
                like: { iPocketTubeHaptics.shared.perform(.primaryAction); vm.like() },
                dislike: { iPocketTubeHaptics.shared.perform(.primaryAction); vm.dislike() },
                share: {
                    if let url = URL(string: "https://www.youtube.com/watch?v=\(current.id)") {
                        presentShareSheet(url: url)
                    }
                },
                downloadVideo: {
                    downloadService.download(
                        video: current,
                        kind: .video,
                        storageLimitMB: store.settings.offlineStorageLimitMB
                    )
                },
                downloadAudio: { audioDownloadService.download(video: current) },
                saveToWatchLater: {
                    let api = vm.api
                    Task { try? await api.addToWatchLater(videoId: current.id) }
                    vm.toastMessage = "Сохранено в «Смотреть позже»"
                },
                transcript: { showTranscript = true },
                description: { showDescriptionSheet = true },
                comments: { showCommentsSheet = true; loadComments() },
                channel: {
                    guard let cid = current.channelId, !cid.isEmpty else { return }
                    NotificationCenter.default.post(name: .openChannel, object: nil, userInfo: ["channelId": cid])
                    playerState.minimize()
                },
                selectRelated: { next in
                    iPocketTubeHaptics.shared.perform(.contentSelection)
                    playerState.play(video: next)
                }
            )
        )
        .id(current.id)
    }
}
#endif
