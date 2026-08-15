import SwiftUI
import iPocketTubeCore

// MARK: - ShortsCardView
//
// Portrait (9:16) card for a single YouTube Short.
// Shows the thumbnail cropped to portrait with a dark gradient overlay
// and the title text at the bottom.  Used inside ShortsRowSection.

struct ShortsCardView: View {
    let video: Video
    let onTap: () -> Void

    @Environment(AuthService.self) private var authService
    @Environment(SettingsStore.self) private var store
    @Environment(\.innerTubeAPI) private var api
    @State private var watchLaterAlert: DownloadAlertItem?
    #if !os(tvOS)
    @Environment(VideoDownloadService.self) private var downloadService
    #endif

    /// Primary thumbnail URL: portrait oardefault.jpg when the API provided one
    /// (reelItemRenderer), landscape thumbnailURL otherwise.
    /// YouTube returns HTTP 200 with a blank black image for oardefault.jpg when
    /// no portrait thumbnail exists, so we skip it for non-reelItemRenderer Shorts.
    private var primaryURL: URL? {
        video.hasPortraitThumbnail ? video.portraitThumbnailURL : video.thumbnailURL
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            ThumbnailFillView(primaryURL: primaryURL, fallbackURLs: video.thumbnailFallbackURLs)
                .saturation(store.settings.themeName.usesMonochromeThumbnails ? 0 : 1)
                .contrast(store.settings.themeName.usesMonochromeThumbnails ? 1.06 : 1)
                .colorMultiply(shortsThumbnailTint)

            // Dark gradient + title overlay at the bottom.
            LinearGradient(
                colors: [.clear, .black.opacity(0.75)],
                startPoint: .center,
                endPoint: .bottom
            )
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(video.title)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)
                    VideoPublicationLabel(video: video)
                        .foregroundStyle(.white.opacity(0.82))
                }
                .padding(8)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .bottomTrailing) {
            let dur = video.formattedDuration
            if !dur.isEmpty {
                Text(dur)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(.black.opacity(0.75))
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .padding(6)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            iPocketTubeHaptics.shared.perform(.contentSelection)
            onTap()
        }
        #if os(tvOS)
        .iPocketTubeCardSurface(cornerRadius: 10, contentPadding: 3)
        #else
        .padding(3)
        #endif
        .contextMenu {
            #if !os(tvOS)
            if let shareURL = URL(string: "https://www.youtube.com/watch?v=\(video.id)") {
                ShareLink(item: shareURL) {
                    Label("Share", systemImage: AppSymbol.share)
                }
            }
            #endif
            if let channelId = video.channelId, !channelId.isEmpty {
                Button {
                    iPocketTubeHaptics.shared.perform(.channelSelection)
                    NotificationCenter.default.post(
                        name: .openChannel,
                        object: nil,
                        userInfo: ["channelId": channelId, "channelTitle": video.channelTitle]
                    )
                } label: {
                    Label("Open Channel", systemImage: AppSymbol.personRectangle)
                }
            }
            if authService.isSignedIn {
                Button {
                    iPocketTubeHaptics.shared.perform(.primaryAction)
                    Task {
                        do {
                            try await api.addToWatchLater(videoId: video.id)
                            watchLaterAlert = DownloadAlertItem(
                                title: String(localized: "Saved to Watch Later", bundle: .module),
                                message: String(localized: "\"\(video.title)\" was added to your Watch Later playlist.", bundle: .module)
                            )
                        } catch {
                            watchLaterAlert = DownloadAlertItem(
                                title: String(localized: "Could Not Save", bundle: .module),
                                message: error.localizedDescription
                            )
                        }
                    }
                } label: {
                    Label("Save to Watch Later", systemImage: AppSymbol.watchLater)
                }
            }
            Button {
                iPocketTubeHaptics.shared.perform(.primaryAction)
                Task { await CurrentQueueStore.shared.append(video) }
            } label: {
                Label("Add to Queue", systemImage: "text.badge.plus")
            }
            Button {
                iPocketTubeHaptics.shared.perform(.primaryAction)
                Task {
                    let count = await CurrentQueueStore.shared.videos.count
                    await CurrentQueueStore.shared.insertNext(video, afterIndex: count - 1)
                }
            } label: {
                Label("Play Next", systemImage: "text.insert")
            }
            if authService.isSignedIn {
                Button(role: .destructive) {
                    Task {
                        if let token = video.notInterestedToken {
                            try? await api.sendFeedback(token: token)
                        } else {
                            try? await api.sendFeedbackForVideo(videoId: video.id, iconType: "NOT_INTERESTED")
                        }
                        NotificationCenter.default.post(
                            name: .hideVideoFromFeed,
                            object: nil,
                            userInfo: ["videoId": video.id]
                        )
                    }
                } label: {
                    Label("Not Interested", systemImage: "hand.raised")
                }
                Button(role: .destructive) {
                    Task {
                        if let token = video.dontLikeToken {
                            try? await api.sendFeedback(token: token)
                        } else {
                            try? await api.sendFeedbackForVideo(videoId: video.id, iconType: "DISLIKE")
                        }
                        NotificationCenter.default.post(
                            name: .hideVideoFromFeed,
                            object: nil,
                            userInfo: ["videoId": video.id]
                        )
                    }
                } label: {
                    Label("Don't Like This Video", systemImage: "hand.thumbsdown")
                }
                if let channelId = video.channelId, !channelId.isEmpty {
                    Button(role: .destructive) {
                        Task {
                            if let token = video.hideChannelToken {
                                try? await api.sendFeedback(token: token)
                            } else {
                                try? await api.sendFeedbackForVideo(videoId: video.id, iconType: "BLOCK_CHANNEL")
                            }
                            store.settings.blockedChannels[channelId] = video.channelTitle
                            NotificationCenter.default.post(
                                name: .hideChannelFromFeed,
                                object: nil,
                                userInfo: ["channelId": channelId]
                            )
                        }
                    } label: {
                        Label("Don't Recommend Channel", systemImage: "person.slash")
                    }
                }
            }
            #if !os(tvOS)
            Button {
                iPocketTubeHaptics.shared.perform(.primaryAction)
                downloadService.download(
                    video: video,
                    kind: .video,
                    saveVideoToPhotos: false,
                    storageLimitMB: store.settings.offlineStorageLimitMB
                )
            } label: {
                Label("Save Video", systemImage: AppSymbol.download)
            }
            .disabled(downloadService.state.isActive)
            #endif
        }
        .alert(item: $watchLaterAlert) { item in
            Alert(title: Text(item.title), message: Text(item.message), dismissButton: .default(Text("OK")))
        }
    }

    private var shortsThumbnailTint: Color {
        switch store.settings.themeName {
        case .matrix:
            return Color(red: 0.76, green: 1.00, blue: 0.82)
        case .monochrome:
            return Color(red: 0.88, green: 1.00, blue: 0.91)
        case .timeline, .colorWashDark, .colorWashLight,
             .spatialDeck, .livingPoster, .signalMap, .prismRooms:
            return .white
        }
    }
}
