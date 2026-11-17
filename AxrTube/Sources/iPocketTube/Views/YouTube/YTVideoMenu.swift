#if os(iOS)
import SwiftUI
import iPocketTubeCore

/// The "⋮" menu under a video card, with YouTube's action set.
/// Saving happens from here or the watch page (or «Смотреть позже» sync).
struct YTVideoMenu: View {
    let video: Video
    var currentPlaylistId: String? = nil

    @Environment(AuthService.self) private var authService
    @Environment(SettingsStore.self) private var store
    @State private var saved = SavedStreamService.shared
    @Environment(\.innerTubeAPI) private var api

    var body: some View {
        Menu {
            Button {
                Task { await CurrentQueueStore.shared.append(video) }
            } label: {
                Label("Добавить в очередь", systemImage: "text.badge.plus")
            }
            // One «Сохранить»: YouTube «Смотреть позже» + on the phone.
            if saved.isSaved(video.id) || currentPlaylistId == "WL" {
                Button(role: .destructive) { saved.remove(video.id) } label: {
                    Label("Удалить из сохранённого", systemImage: "bookmark.slash")
                }
            } else {
                Button { saved.save(video, audioOnly: saved.wantsAudioOnlyDownload) } label: {
                    Label("Сохранить", systemImage: "bookmark")
                }
                Button { saved.save(video, audioOnly: true) } label: {
                    Label("Сохранить только звук", systemImage: "headphones")
                }
            }
            if let url = URL(string: "https://www.youtube.com/watch?v=\(video.id)") {
                ShareLink(item: url) { Label("Поделиться", systemImage: "square.and.arrow.up") }
            }
            if let channelId = video.channelId, !channelId.isEmpty {
                Button {
                    NotificationCenter.default.post(
                        name: .openChannel,
                        object: nil,
                        userInfo: ["channelId": channelId, "channelTitle": video.channelTitle]
                    )
                } label: {
                    Label("Перейти на канал", systemImage: "person.crop.square")
                }
            }
            if authService.isSignedIn {
                Divider()
                Button(role: .destructive) { sendNotInterested() } label: {
                    Label("Не интересует", systemImage: "nosign")
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .rotationEffect(.degrees(90))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(YTColor.primaryText)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Действия")
    }

    private func sendNotInterested() {
        let id = video.id
        let token = video.notInterestedToken
        Task {
            if let token {
                try? await api.sendFeedback(token: token)
            } else {
                try? await api.sendFeedbackForVideo(videoId: id, iconType: "NOT_INTERESTED")
            }
            NotificationCenter.default.post(name: .hideVideoFromFeed, object: nil, userInfo: ["videoId": id])
        }
    }
}
#endif
