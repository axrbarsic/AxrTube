import Foundation

/// Finds the channel avatar inside a video renderer: `channelThumbnailSupportedRenderers`
/// (WEB videoRenderer), `channelThumbnail` (compact renderers) or `avatarViewModel`
/// (lockup view models).
enum ChannelAvatarExtractor {
    static func avatarURL(in renderer: [String: Any]) -> URL? {
        if let supported = renderer["channelThumbnailSupportedRenderers"] as? [String: Any],
           let link = supported["channelThumbnailWithLinkRenderer"] as? [String: Any],
           let url = bestURL(link["thumbnail"]) {
            return url
        }
        if let url = bestURL(renderer["channelThumbnail"]) { return url }
        return findAvatarViewModel(renderer, depth: 0)
    }

    private static func findAvatarViewModel(_ object: Any, depth: Int) -> URL? {
        guard depth < 12 else { return nil }
        if let dict = object as? [String: Any] {
            if let avatar = dict["avatarViewModel"] as? [String: Any],
               let image = avatar["image"] as? [String: Any],
               let sources = image["sources"] as? [[String: Any]],
               let raw = sources.last?["url"] as? String {
                return normalized(raw)
            }
            for value in dict.values {
                if let url = findAvatarViewModel(value, depth: depth + 1) { return url }
            }
        } else if let array = object as? [Any] {
            for value in array {
                if let url = findAvatarViewModel(value, depth: depth + 1) { return url }
            }
        }
        return nil
    }

    private static func bestURL(_ thumbnail: Any?) -> URL? {
        guard let dict = thumbnail as? [String: Any],
              let thumbs = dict["thumbnails"] as? [[String: Any]],
              let raw = thumbs.last?["url"] as? String else { return nil }
        return normalized(raw)
    }

    private static func normalized(_ raw: String) -> URL? {
        URL(string: raw.hasPrefix("//") ? "https:" + raw : raw)
    }
}

/// Resolves channel avatars missing from feed responses (TV tiles), one request
/// per channel, at most four at a time, cached for the app session.
public actor ChannelAvatarCache {
    public static let shared = ChannelAvatarCache()

    private var resolved: [String: URL?] = [:]
    private var inFlight: [String: Task<URL?, Never>] = [:]
    private var running = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private let limit = 4

    public func cached(_ channelID: String) -> URL?? { resolved[channelID] }

    public func avatar(for channelID: String, fetch: @escaping @Sendable () async -> URL?) async -> URL? {
        if let known = resolved[channelID] { return known }
        if let task = inFlight[channelID] { return await task.value }
        let task = Task<URL?, Never> { [weak self] in
            guard let self else { return nil }
            await self.acquire()
            let url = await fetch()
            await self.release()
            return url
        }
        inFlight[channelID] = task
        let url = await task.value
        inFlight[channelID] = nil
        resolved[channelID] = url
        return url
    }

    private func acquire() async {
        if running < limit {
            running += 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty {
            running -= 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}
