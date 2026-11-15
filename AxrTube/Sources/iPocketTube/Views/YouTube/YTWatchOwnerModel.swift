#if os(iOS)
import Foundation
import Observation
import iPocketTubeCore

/// Owner row state for the watch page. Signed-in accounts subscribe on
/// YouTube; guests follow the channel locally (the app's guest subscriptions).
@MainActor
@Observable
final class YTWatchOwnerModel {
    private(set) var info = WatchOwnerInfo()
    private(set) var isSubscribed = false
    private(set) var isChanging = false
    private(set) var loadedVideoID: String?

    func load(video: Video, api: InnerTubeAPI, signedIn: Bool) async {
        guard loadedVideoID != video.id else { return }
        loadedVideoID = video.id
        info = WatchOwnerInfo(channelId: video.channelId, channelTitle: video.channelTitle)
        let channelID = video.channelId
        if !signedIn, let channelID {
            isSubscribed = await LocalSubscriptionStore.shared.isFollowing(channelID)
        } else {
            isSubscribed = false
        }
        guard let fetched = try? await api.fetchWatchOwner(videoId: video.id, signedIn: signedIn),
              loadedVideoID == video.id else { return }
        info.avatarURL = fetched.avatarURL ?? info.avatarURL
        info.subscriberText = fetched.subscriberText
        info.likeCountText = fetched.likeCountText
        if info.channelId == nil { info.channelId = fetched.channelId }
        if signedIn, let subscribed = fetched.isSubscribed { isSubscribed = subscribed }
    }

    /// Returns a message for the toast, or nil when nothing should be shown.
    func toggleSubscription(api: InnerTubeAPI, signedIn: Bool) async -> String? {
        guard let channelID = info.channelId, !channelID.isEmpty, !isChanging else { return nil }
        isChanging = true
        defer { isChanging = false }
        let target = !isSubscribed
        if signedIn {
            do {
                if target { try await api.subscribe(channelId: channelID) } else { try await api.unsubscribe(channelId: channelID) }
            } catch {
                return "Не удалось изменить подписку"
            }
        } else if target {
            await LocalSubscriptionStore.shared.follow(LocalChannel(
                id: channelID,
                title: info.channelTitle ?? "",
                thumbnailURL: info.avatarURL
            ))
        } else {
            await LocalSubscriptionStore.shared.unfollow(channelId: channelID)
        }
        isSubscribed = target
        return target ? "Подписка оформлена" : "Подписка отменена"
    }
}
#endif
