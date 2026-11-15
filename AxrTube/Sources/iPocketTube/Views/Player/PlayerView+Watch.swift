#if os(iOS)
import SwiftUI
import iPocketTubeCore

// MARK: - YouTube watch page layout
//
// Portrait: 16:9 player on top, details and related videos below; comments
// slide over the details area while the video keeps playing above.
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
                        .overlay(alignment: .bottom) {
                            if !vm.controlsVisible { YTThinProgress(vm: vm).frame(height: 2) }
                        }
                    ZStack {
                        watchDetails
                        if showCommentsSheet {
                            YTCommentsSheet(videoID: watchVideo.id, onClose: { showCommentsSheet = false })
                                .transition(.move(edge: .bottom))
                        }
                    }
                    .animation(.easeOut(duration: 0.22), value: showCommentsSheet)
                }
                .background(YTColor.background)
                // Pickers and sheets cover the whole watch page, not just the player.
                .overlay { overlayStack }
                .onChange(of: audioDownloadService.lastMessage) { _, message in
                    guard let message else { return }
                    vm.toastMessage = message
                    audioDownloadService.lastMessage = nil
                }
            }
        }
        .background(Color.black.ignoresSafeArea(edges: .top))
        .task(id: watchVideo.id) {
            await ownerModel.load(video: watchVideo, api: vm.api, signedIn: authService.isSignedIn)
        }
        .onChange(of: watchVideo.id) { _, _ in showCommentsSheet = false }
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
        let signedIn = authService.isSignedIn
        return YTWatchDetails(
            video: current,
            related: vm.relatedVideos,
            likeStatus: vm.likeStatus,
            owner: ownerModel.info,
            isSubscribed: ownerModel.isSubscribed,
            isSignedIn: signedIn,
            isDownloading: downloadService.state.isActive
                || audioDownloadService.isDownloading(videoID: current.id),
            actions: .init(
                like: {
                    guard signedIn else { vm.toastMessage = "Войдите, чтобы оценить видео"; return }
                    iPocketTubeHaptics.shared.perform(.primaryAction)
                    vm.like()
                },
                dislike: {
                    guard signedIn else { vm.toastMessage = "Войдите, чтобы оценить видео"; return }
                    iPocketTubeHaptics.shared.perform(.primaryAction)
                    vm.dislike()
                },
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
                    Task {
                        do {
                            try await api.addToWatchLater(videoId: current.id)
                            vm.toastMessage = "Сохранено в «Смотреть позже»"
                        } catch {
                            vm.toastMessage = "Не удалось сохранить видео"
                        }
                    }
                },
                transcript: { showTranscript = true },
                description: { showDescriptionSheet = true },
                comments: { showCommentsSheet = true },
                channel: {
                    guard let cid = ownerModel.info.channelId ?? current.channelId, !cid.isEmpty else { return }
                    NotificationCenter.default.post(name: .openChannel, object: nil, userInfo: ["channelId": cid])
                    playerState.minimize()
                },
                subscribe: {
                    iPocketTubeHaptics.shared.perform(.primaryAction)
                    let api = vm.api
                    Task {
                        if let message = await ownerModel.toggleSubscription(api: api, signedIn: signedIn) {
                            vm.toastMessage = message
                        }
                    }
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
