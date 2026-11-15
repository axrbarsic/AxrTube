import Foundation

/// Channel row and like counter data shown under the player on the watch page.
public struct WatchOwnerInfo: Sendable, Equatable {
    public var channelId: String?
    public var channelTitle: String?
    public var avatarURL: URL?
    public var subscriberText: String?
    public var likeCountText: String?
    /// `nil` when the response does not reveal the account's subscription state.
    public var isSubscribed: Bool?

    public init(
        channelId: String? = nil,
        channelTitle: String? = nil,
        avatarURL: URL? = nil,
        subscriberText: String? = nil,
        likeCountText: String? = nil,
        isSubscribed: Bool? = nil
    ) {
        self.channelId = channelId
        self.channelTitle = channelTitle
        self.avatarURL = avatarURL
        self.subscriberText = subscriberText
        self.likeCountText = likeCountText
        self.isSubscribed = isSubscribed
    }
}

extension InnerTubeAPI {
    /// Reads owner, subscriber count and like count from the WEB `/next` page.
    public func fetchWatchOwner(videoId: String, signedIn: Bool) async throws -> WatchOwnerInfo {
        var body = makeBody(client: webClientContext)
        body["videoId"] = videoId
        let json: [String: Any]
        if signedIn, let authed = try? await post(endpoint: "next", body: body, useAuth: true) {
            json = authed
        } else {
            json = try await post(endpoint: "next", body: body)
        }
        return WatchOwnerParser.parse(json, text: { self.extractText($0) })
    }

    /// Subscribes the signed-in account to a channel.
    public func subscribe(channelId: String) async throws {
        var body = makeBody(client: tvClientContext)
        body["channelIds"] = [channelId]
        _ = try await postTV(endpoint: "subscription/subscribe", body: body)
    }

    /// Unsubscribes the signed-in account from a channel.
    public func unsubscribe(channelId: String) async throws {
        var body = makeBody(client: tvClientContext)
        body["channelIds"] = [channelId]
        _ = try await postTV(endpoint: "subscription/unsubscribe", body: body)
    }
}

enum WatchOwnerParser {
    static func parse(_ json: [String: Any], text: ([String: Any]) -> String?) -> WatchOwnerInfo {
        var info = WatchOwnerInfo()

        func walk(_ object: Any, depth: Int) {
            guard depth < 60 else { return }
            if let array = object as? [Any] {
                array.forEach { walk($0, depth: depth + 1) }
                return
            }
            guard let dict = object as? [String: Any] else { return }

            if info.channelTitle == nil, let owner = dict["videoOwnerRenderer"] as? [String: Any] {
                info.channelTitle = (owner["title"] as? [String: Any]).flatMap(text)
                info.subscriberText = (owner["subscriberCountText"] as? [String: Any]).flatMap(text)
                let thumbs = (owner["thumbnail"] as? [String: Any])?["thumbnails"] as? [[String: Any]]
                if let raw = thumbs?.last?["url"] as? String {
                    info.avatarURL = URL(string: raw.hasPrefix("//") ? "https:" + raw : raw)
                }
                let browse = ((owner["navigationEndpoint"] as? [String: Any])?["browseEndpoint"] as? [String: Any])
                info.channelId = browse?["browseId"] as? String
            }
            if info.likeCountText == nil, let like = dict["likeButtonViewModel"] as? [String: Any] {
                info.likeCountText = firstValue(forKey: "defaultButtonViewModel", in: like, depth: 0)
                    .flatMap { firstButtonTitle(in: $0, depth: 0) } ?? firstButtonTitle(in: like, depth: 0)
            }
            if info.isSubscribed == nil {
                if let button = dict["subscribeButtonRenderer"] as? [String: Any], let subscribed = button["subscribed"] as? Bool {
                    info.isSubscribed = subscribed
                } else if let entity = dict["subscriptionStateEntity"] as? [String: Any], let subscribed = entity["subscribed"] as? Bool {
                    info.isSubscribed = subscribed
                }
            }
            for value in dict.values { walk(value, depth: depth + 1) }
        }

        walk(json, depth: 0)
        return info
    }

    private static func firstValue(forKey key: String, in object: Any, depth: Int) -> Any? {
        guard depth < 20 else { return nil }
        if let dict = object as? [String: Any] {
            if let value = dict[key] { return value }
            for value in dict.values {
                if let found = firstValue(forKey: key, in: value, depth: depth + 1) { return found }
            }
        } else if let array = object as? [Any] {
            for value in array {
                if let found = firstValue(forKey: key, in: value, depth: depth + 1) { return found }
            }
        }
        return nil
    }

    private static func firstButtonTitle(in object: Any, depth: Int) -> String? {
        guard depth < 20 else { return nil }
        if let dict = object as? [String: Any] {
            if let button = dict["buttonViewModel"] as? [String: Any],
               let title = button["title"] as? String, !title.isEmpty {
                return title
            }
            for value in dict.values {
                if let found = firstButtonTitle(in: value, depth: depth + 1) { return found }
            }
        } else if let array = object as? [Any] {
            for value in array {
                if let found = firstButtonTitle(in: value, depth: depth + 1) { return found }
            }
        }
        return nil
    }
}
