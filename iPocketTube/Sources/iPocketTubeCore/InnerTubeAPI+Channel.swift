import Foundation
import os

private let tubeLog = Logger(subsystem: appSubsystem, category: "InnerTube")

// MARK: - Channel endpoints

extension InnerTubeAPI {

    public func fetchChannel(channelId: String) async throws -> (channel: Channel, videos: VideoGroup) {
        // @handle strings are not valid browseIds — resolve to the real UC… channel ID first.
        let resolvedId: String
        if channelId.hasPrefix("@") {
            tubeLog.notice("fetchChannel resolving handle \(channelId, privacy: .public)")
            resolvedId = try await resolveChannelHandle(channelId)
            tubeLog.notice("fetchChannel resolved \(channelId, privacy: .public) → \(resolvedId, privacy: .public)")
        } else {
            resolvedId = channelId
        }
        var body = makeBody(client: webClientContext)
        body["browseId"] = resolvedId
        tubeLog.notice("fetchChannel browseId=\(resolvedId, privacy: .public)")
        let data = try await post(endpoint: "browse", body: body)
        return try parseChannel(from: data, channelId: resolvedId)
    }

    /// Lightweight channel thumbnail fetch.
    /// Requests the About tab (params `EgVhYm91dA==`) which returns only channel
    /// metadata (no video grid), making the response much smaller than a full channel page.
    /// Used by BrowseViewModel.enrichChannelAvatars() to patch avatar URLs into the
    /// channel list after the initial fast tile-based load.
    public func fetchChannelThumbnailURL(channelId: String) async throws -> URL? {
        let resolvedId: String
        if channelId.hasPrefix("@") {
            resolvedId = try await resolveChannelHandle(channelId)
        } else {
            resolvedId = channelId
        }
        var body = makeBody(client: webClientContext)
        body["browseId"] = resolvedId
        body["params"] = "EgVhYm91dA=="  // About tab — header only, no video grid
        let data = try await post(endpoint: "browse", body: body)
        let (channel, _) = try parseChannel(from: data, channelId: resolvedId)
        return channel.thumbnailURL
    }

    public func fetchChannelVideos(channelId: String, continuationToken: String? = nil) async throws -> VideoGroup {
        var body = makeBody(client: webClientContext, continuationToken: continuationToken)
        if continuationToken == nil {
            body["browseId"] = channelId
            body["params"] = "EgZ2aWRlb3PyBgQKAjoA"  // "Videos" tab parameter
        }
        let videosParams = (body["params"] as? String) ?? "nil"
        tubeLog.notice("fetchChannelVideos browseId=\(channelId, privacy: .public) hasContinuation=\(continuationToken != nil, privacy: .public) params=\(videosParams, privacy: .public)")
        let data = try await post(endpoint: "browse", body: body)
        return try parseVideoGroup(from: data, title: nil)
    }

    // MARK: - Private channel helpers

    /// Resolves a YouTube `@handle` to the canonical `UC…` channel ID using the
    /// InnerTube `navigation/resolve_url` endpoint.
    ///
    /// Some channels (e.g. ones still on a legacy custom-URL slug rather than a
    /// true `@handle` — confirmed live for `@nieuwsuur`, which redirects to
    /// `/Nieuwsuur`) make `resolve_url` return a `urlEndpoint` instead of a
    /// `browseEndpoint`, with no `browseId` anywhere in the response. The old
    /// fallback ("pass the handle through unchanged, /browse accepts @handle as
    /// browseId") does NOT hold for these — confirmed live: `/browse` with
    /// `browseId: "@nieuwsuur"` returns HTTP 400 — which is GitHub issue #79.
    ///
    /// So when `resolve_url` doesn't yield a `browseId`, fall back to searching
    /// for the handle and matching a `channelRenderer` result's
    /// `canonicalBaseUrl` against it — this is how the real channel ID
    /// (`UCExcZNwh_3Mwm4fF4VSiu2w` for `@nieuwsuur`) was found and verified live.
    private func resolveChannelHandle(_ handle: String) async throws -> String {
        let handleURL = "https://www.youtube.com/\(handle)"
        var body = makeBody(client: webClientContext)
        body["url"] = handleURL
        tubeLog.notice("resolveChannelHandle url=\(handleURL, privacy: .public)")
        do {
            let data = try await post(endpoint: "navigation/resolve_url", body: body)
            // Standard shape: { "endpoint": { "browseEndpoint": { "browseId": "UCxxx" } } }
            let endpoint = data["endpoint"] as? [String: Any]
            if let browseId = (endpoint?["browseEndpoint"] as? [String: Any])?["browseId"] as? String,
               !browseId.isEmpty {
                tubeLog.notice("resolveChannelHandle resolved \(handle, privacy: .public) → \(browseId, privacy: .public)")
                return browseId
            }
            // Some channels return a urlEndpoint instead of browseEndpoint — fall through.
            let topKeys = data.keys.joined(separator: ", ")
            tubeLog.warning("resolveChannelHandle: unexpected response keys=[\(topKeys, privacy: .public)] — trying search fallback")
        } catch {
            // resolve_url threw (e.g. HTTP error, consent wall in EU) — fall through.
            tubeLog.warning("resolveChannelHandle: resolve_url threw \(error, privacy: .public) — trying search fallback")
        }
        if let found = try await searchForChannelHandle(handle) {
            tubeLog.notice("resolveChannelHandle: search fallback resolved \(handle, privacy: .public) → \(found, privacy: .public)")
            return found
        }
        // Last resort: pass the handle through unchanged. YouTube's /browse
        // endpoint accepts @handle as a browseId for most (but not all) channels.
        tubeLog.warning("resolveChannelHandle: search fallback found no match — falling back to handle-as-browseId")
        return handle
    }

    /// Searches for `handle` (e.g. "@nieuwsuur") and returns the `UC…` channel ID
    /// of the first `channelRenderer` result whose `canonicalBaseUrl` matches it.
    private func searchForChannelHandle(_ handle: String) async throws -> String? {
        let query = handle.hasPrefix("@") ? String(handle.dropFirst()) : handle
        var body = makeBody(client: webClientContext)
        body["query"] = query
        body["params"] = "EgIQAg%3D%3D" // search filter: channels only
        let data = try await post(endpoint: "search", body: body)
        let targetPath = "/" + handle.lowercased()

        var found: String? = nil
        func walk(_ obj: Any, depth: Int = 0) {
            guard found == nil, depth < 50 else { return }
            if let dict = obj as? [String: Any] {
                if let renderer = dict["channelRenderer"] as? [String: Any],
                   let channelId = renderer["channelId"] as? String, !channelId.isEmpty {
                    let runs = ((renderer["longBylineText"] as? [String: Any])?["runs"] as? [[String: Any]]) ?? []
                    let canonicalBaseUrl = runs.first
                        .flatMap { ($0["navigationEndpoint"] as? [String: Any]) }
                        .flatMap { ($0["browseEndpoint"] as? [String: Any]) }
                        .flatMap { $0["canonicalBaseUrl"] as? String }
                    if canonicalBaseUrl?.lowercased() == targetPath {
                        found = channelId
                        return
                    }
                }
                for value in dict.values { walk(value, depth: depth + 1) }
            } else if let arr = obj as? [Any] {
                for item in arr { walk(item, depth: depth + 1) }
            }
        }
        walk(data)
        return found
    }

    private func parseChannel(from json: [String: Any], channelId: String) throws -> (Channel, VideoGroup) {
        let headerDict = json["header"] as? [String: Any]
        tubeLog.notice("parseChannel header keys=[\((headerDict?.keys.joined(separator: ",")) ?? "nil", privacy: .public)]")
        let header = headerDict?["c4TabbedHeaderRenderer"] as? [String: Any]
            ?? headerDict?["pageHeaderRenderer"] as? [String: Any]
        let title = header.flatMap { $0["title"] as? String }
            ?? (header?["pageTitle"] as? String)
            ?? {
                // pageHeaderRenderer uses content.pageHeaderViewModel.title.content
                if let content = (header?["content"] as? [String: Any])?["pageHeaderViewModel"] as? [String: Any] {
                    return (content["title"] as? [String: Any]).flatMap { extractText($0) }
                        ?? content["title"] as? String
                }
                return nil
            }()
            ?? ""
        tubeLog.notice("parseChannel header=\(header != nil ? "found" : "nil", privacy: .public) title='\(title, privacy: .public)'")
        let description = header
            .flatMap { $0["description"] as? [String: Any] }
            .flatMap { extractText($0) }
        // avatar: c4TabbedHeaderRenderer uses avatar.thumbnails, pageHeaderRenderer uses banner or content avatar
        let thumbURL: URL? = {
            // c4TabbedHeaderRenderer path
            if let url = ((header?["avatar"] as? [String: Any])?["thumbnails"] as? [[String: Any]])?
                .last.flatMap({ $0["url"] as? String }).flatMap({ URL(string: $0) }) {
                return url
            }
            // pageHeaderViewModel path: content.pageHeaderViewModel.image.decoratedAvatarViewModel.avatar.avatarViewModel.image.sources
            if let hvm = (header?["content"] as? [String: Any])?["pageHeaderViewModel"] as? [String: Any],
               let sources = ((((hvm["image"] as? [String: Any])?["decoratedAvatarViewModel"] as? [String: Any])?["avatar"] as? [String: Any])?["avatarViewModel"] as? [String: Any])?["image"] as? [String: Any],
               let urlStr = (sources["sources"] as? [[String: Any]])?.last?["url"] as? String {
                return URL(string: urlStr)
            }
            // metadata fallback: json.metadata.channelMetadataRenderer.avatar.thumbnails
            if let urlStr = (((json["metadata"] as? [String: Any])?["channelMetadataRenderer"] as? [String: Any])?["avatar"] as? [String: Any]).flatMap({ ($0["thumbnails"] as? [[String: Any]])?.last?["url"] as? String }) {
                return URL(string: urlStr)
            }
            return nil
        }()
        let subscribers = header.flatMap { $0["subscriberCountText"] as? [String: Any] }.flatMap { extractText($0) }

        // Prefer the canonical UC… channelId from channelMetadataRenderer.externalId over
        // the browseId parameter — when a @handle is passed as browseId the parameter is
        // the handle string, not the UC… ID. Using externalId ensures the stored Channel.id
        // is always the stable UC-format identifier regardless of the browse path used (#185).
        let resolvedChannelId: String = {
            if let meta = (json["metadata"] as? [String: Any])?["channelMetadataRenderer"] as? [String: Any],
               let extId = meta["externalId"] as? String, extId.hasPrefix("UC") {
                if extId != channelId {
                    tubeLog.notice("parseChannel: externalId=\(extId, privacy: .public) replaces browseId=\(channelId, privacy: .public)")
                }
                return extId
            }
            return channelId
        }()

        let channel = Channel(
            id: resolvedChannelId,
            title: title,
            description: description,
            thumbnailURL: thumbURL,
            subscriberCount: subscribers
        )
        let videoGroup = try parseVideoGroup(from: json, title: title)
        return (channel, videoGroup)
    }

    // MARK: – Guide channels parser (/guide endpoint)
    //
    // The TV guide sidebar returns guideEntryRenderer items inside
    // guideSubscriptionsSectionRenderer which carry:
    //   navigationEndpoint.browseEndpoint.browseId  → channel ID
    //   formattedTitle / title                       → channel name
    //   thumbnail.thumbnails                         → avatar URL
    func parseGuideChannels(from json: [String: Any]) -> [Channel] {
        var channels: [Channel] = []
        var seen = Set<String>()
        var firstEntryDumped = false

        func walk(_ obj: Any, depth: Int = 0) {
            guard depth < 50 else {
                tubeLog.warning("parseGuideChannels: walk depth limit (50) reached — skipping subtree")
                return
            }
            if let dict = obj as? [String: Any] {
                if let entry = dict["guideEntryRenderer"] as? [String: Any] {
                    let browseEndpoint = (entry["navigationEndpoint"] as? [String: Any])?["browseEndpoint"] as? [String: Any]
                    let channelId = browseEndpoint?["browseId"] as? String

                    // Dump the first entry that has a browseId (channel entry) regardless of thumbnail
                    if !firstEntryDumped, let channelId, !channelId.isEmpty {
                        firstEntryDumped = true
                        let allKeys = entry.keys.sorted()
                        tubeLog.notice("guideEntryRenderer (channel) keys: \(allKeys, privacy: .public)")
                        if let data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]),
                           let str = String(data: data, encoding: .utf8) {
                            tubeLog.notice("guideEntryRenderer (channel) JSON: \(String(str.prefix(1500)), privacy: .public)")
                        }
                    }

                    guard let channelId, !channelId.isEmpty else { return }

                    let title = (entry["formattedTitle"] as? [String: Any]).flatMap { extractText($0) }
                        ?? entry["title"] as? String
                        ?? ""

                    // Try several known thumbnail paths in the TV guide
                    let thumbURL: URL? = {
                        // Standard path
                        if let url = ((entry["thumbnail"] as? [String: Any])?["thumbnails"] as? [[String: Any]])?
                            .last.flatMap({ $0["url"] as? String }).flatMap({ URL(string: $0) }) { return url }
                        // thumbnailDetails path
                        if let url = ((entry["thumbnailDetails"] as? [String: Any])?["thumbnails"] as? [[String: Any]])?
                            .last.flatMap({ $0["url"] as? String }).flatMap({ URL(string: $0) }) { return url }
                        // Icon path
                        if let iconDict = entry["icon"] as? [String: Any],
                           let thumbs = iconDict["thumbnails"] as? [[String: Any]],
                           let urlStr = thumbs.last?["url"] as? String,
                           let url = URL(string: urlStr) { return url }
                        return nil
                    }()

                    // Only add channel-looking browseIds (UC... or @handle) — skip Home/Trending/etc.
                    guard channelId.hasPrefix("UC") || channelId.hasPrefix("@") else { return }

                    let channel = Channel(id: channelId, title: title, thumbnailURL: thumbURL)
                    if seen.insert(channelId).inserted {
                        channels.append(channel)
                    }
                    return
                }
                for value in dict.values { walk(value, depth: depth + 1) }
            } else if let arr = obj as? [Any] {
                for item in arr { walk(item, depth: depth + 1) }
            }
        }

        walk(json)
        let withThumbs = channels.filter { $0.thumbnailURL != nil }.count
        // Sort alphabetically so the list is stable and predictable regardless of
        // the order YouTube's guide API returns entries. Matches LocalSubscriptionStore.
        channels.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        tubeLog.notice("parseGuideChannels → \(channels.count, privacy: .public) channels, \(withThumbs, privacy: .public) with thumbnail")
        return channels
    }

    // MARK: – Channel renderer parser (TV/WEB client subscriptions "Channels" tab)
    //
    // Handles channelRenderer, gridChannelRenderer, compactChannelRenderer, and
    // TVHTML5 tileRenderer with TILE_CONTENT_TYPE_CHANNEL.
    private func parseChannelRenderers(from json: [String: Any]) -> [Channel] {
        var channels: [Channel] = []
        var seen = Set<String>()
        // Collect all distinct renderer key names encountered for diagnostics
        var encounteredRendererKeys = Set<String>()

        func extractChannel(from renderer: [String: Any]) -> Channel? {
            // channelId: direct "channelId" key, or from navigationEndpoint.browseEndpoint.browseId
            let channelId: String? = renderer["channelId"] as? String
                ?? (renderer["navigationEndpoint"] as? [String: Any])
                    .flatMap { ($0["browseEndpoint"] as? [String: Any])?["browseId"] as? String }
            guard let channelId, !channelId.isEmpty else { return nil }

            let title = (renderer["title"] as? [String: Any]).flatMap { extractText($0) }
                ?? renderer["title"] as? String
                ?? ""

            // Avatars: channelRenderer uses "thumbnail"; gridChannelRenderer may use
            // "thumbnail" or "channelThumbnailSupportedRenderers.channelThumbnailRenderer.thumbnail"
            let primaryThumb = (renderer["thumbnail"] as? [String: Any])?["thumbnails"] as? [[String: Any]]
            let ctsr = (renderer["channelThumbnailSupportedRenderers"] as? [String: Any])?["channelThumbnailRenderer"] as? [String: Any]
            let secondaryThumb = (ctsr?["thumbnail"] as? [String: Any])?["thumbnails"] as? [[String: Any]]
            let thumbSources: [[String: Any]]? = primaryThumb ?? secondaryThumb
            let thumbURL = thumbSources?.last.flatMap { $0["url"] as? String }.flatMap { URL(string: $0) }

            let subscriberCount = (renderer["subscriberCountText"] as? [String: Any])
                .flatMap { extractText($0) }
                ?? (renderer["videoCountText"] as? [String: Any]).flatMap { extractText($0) }

            return Channel(
                id: channelId,
                title: title,
                thumbnailURL: thumbURL,
                subscriberCount: subscriberCount
            )
        }

        func extractChannelFromTile(_ tile: [String: Any]) -> Channel? {
            guard (tile["contentType"] as? String) == "TILE_CONTENT_TYPE_CHANNEL" else { return nil }
            let onSelectCommand = tile["onSelectCommand"] as? [String: Any]
            let channelId: String? = (onSelectCommand?["browseEndpoint"] as? [String: Any])?["browseId"] as? String
                ?? (onSelectCommand?["innertubeCommand"] as? [String: Any])
                    .flatMap { ($0["browseEndpoint"] as? [String: Any])?["browseId"] as? String }
            guard let channelId, !channelId.isEmpty else { return nil }
            let tileMetadata = (tile["metadata"] as? [String: Any])?["tileMetadataRenderer"] as? [String: Any]
            let title = (tileMetadata?["title"] as? [String: Any]).flatMap { extractText($0) } ?? ""
            let tileHeader = (tile["header"] as? [String: Any])?["tileHeaderRenderer"] as? [String: Any]
            let thumbURL = ((tileHeader?["thumbnail"] as? [String: Any])?["thumbnails"] as? [[String: Any]])?
                .last.flatMap { $0["url"] as? String }.flatMap { URL(string: $0) }
            return Channel(id: channelId, title: title, thumbnailURL: thumbURL)
        }

        var avatarLockupDumped = false
        var notificationDumped = false

        func walk(_ obj: Any, depth: Int = 0) {
            guard depth < 50 else {
                tubeLog.warning("parseChannelRenderers: walk depth limit (50) reached — skipping subtree")
                return
            }
            if let dict = obj as? [String: Any] {
                // Track all "xxxRenderer" keys at this level for diagnostics
                for k in dict.keys where k.hasSuffix("Renderer") || k.hasSuffix("ViewModel") {
                    encounteredRendererKeys.insert(k)
                }
                // Dump the first avatarLockupRenderer that actually has a navigationEndpoint (i.e. is a channel, not a sort header)
                if !avatarLockupDumped, let lockup = dict["avatarLockupRenderer"] as? [String: Any],
                   lockup["navigationEndpoint"] != nil {
                    avatarLockupDumped = true
                    if let data = try? JSONSerialization.data(withJSONObject: lockup, options: [.sortedKeys]),
                       let str = String(data: data, encoding: .utf8) {
                        tubeLog.notice("avatarLockupRenderer (with nav) JSON: \(String(str.prefix(2000)), privacy: .public)")
                    }
                }
                // Dump the first notificationMultiActionRenderer (these appear per-channel)
                if !notificationDumped, let notif = dict["notificationMultiActionRenderer"] as? [String: Any] {
                    notificationDumped = true
                    if let data = try? JSONSerialization.data(withJSONObject: notif, options: [.sortedKeys]),
                       let str = String(data: data, encoding: .utf8) {
                        tubeLog.notice("notificationMultiActionRenderer JSON: \(String(str.prefix(2000)), privacy: .public)")
                    }
                }
                // TVHTML5 channel tile
                if let tile = dict["tileRenderer"] as? [String: Any],
                   let channel = extractChannelFromTile(tile) {
                    if seen.insert(channel.id).inserted { channels.append(channel) }
                    return
                }
                // WEB channelRenderer / gridChannelRenderer / compactChannelRenderer
                let rendererKeys = ["channelRenderer", "gridChannelRenderer", "compactChannelRenderer"]
                if let key = rendererKeys.first(where: { dict[$0] is [String: Any] }),
                   let renderer = dict[key] as? [String: Any],
                   let channel = extractChannel(from: renderer) {
                    if seen.insert(channel.id).inserted { channels.append(channel) }
                    return
                }
                for value in dict.values { walk(value, depth: depth + 1) }
            } else if let arr = obj as? [Any] {
                for item in arr { walk(item, depth: depth + 1) }
            }
        }

        walk(json)
        let withThumbs = channels.filter { $0.thumbnailURL != nil }.count
        let rendererSample = Array(encounteredRendererKeys.sorted().prefix(12))
        tubeLog.notice("parseChannelRenderers → \(channels.count, privacy: .public) channels, \(withThumbs, privacy: .public) with thumbnail | renderer keys seen: \(rendererSample, privacy: .public)")
        return channels
    }

    // MARK: – Subscribed channels parser (TVHTML5 fallback)
    //
    // Extracts unique Channel objects from a TVHTML5 FEsubscriptions response.
    // Each video tileRenderer carries the channelId and channel name in its metadata;
    // thumbnail URLs and subscriber counts are not present and remain nil.
    func parseSubscribedChannels(from json: [String: Any]) -> [Channel] {
        var channels: [Channel] = []
        var seen = Set<String>()

        func channelFromTile(_ tile: [String: Any]) -> Channel? {
            guard (tile["contentType"] as? String) == "TILE_CONTENT_TYPE_VIDEO" else { return nil }
            let onSelectCommand = tile["onSelectCommand"] as? [String: Any]
            let navigationEndpoint = tile["navigationEndpoint"] as? [String: Any]
            let watchEndpoint: [String: Any]? = {
                if let ep = onSelectCommand?["watchEndpoint"] as? [String: Any] { return ep }
                if let inner = onSelectCommand?["innertubeCommand"] as? [String: Any],
                   let ep = inner["watchEndpoint"] as? [String: Any] { return ep }
                if let ep = navigationEndpoint?["watchEndpoint"] as? [String: Any] { return ep }
                return nil
            }()
            let channelId: String? = watchEndpoint?["channelId"] as? String
                ?? (onSelectCommand?["browseEndpoint"] as? [String: Any])?["browseId"] as? String
                ?? {
                    guard let showMenu = (tile["onLongPressCommand"] as? [String: Any])?["showMenuCommand"] as? [String: Any],
                          let subtitleText = (showMenu["subtitle"] as? [String: Any])?["simpleText"] as? String,
                          let atIndex = subtitleText.firstIndex(of: "@")
                    else { return nil }
                    return subtitleText[atIndex...]
                        .components(separatedBy: .whitespacesAndNewlines)
                        .first
                        .map { String($0) }
                }()
            guard let channelId, !channelId.isEmpty else { return nil }

            let tileMetadata = (tile["metadata"] as? [String: Any])?["tileMetadataRenderer"] as? [String: Any]
            let channelTitle: String = {
                guard let lines = tileMetadata?["lines"] as? [[String: Any]],
                      let firstLine = lines.first,
                      let lineRenderer = firstLine["lineRenderer"] as? [String: Any],
                      let items = lineRenderer["items"] as? [[String: Any]],
                      let firstItem = items.first,
                      let lineItemRenderer = firstItem["lineItemRenderer"] as? [String: Any],
                      let text = lineItemRenderer["text"] as? [String: Any]
                else { return "" }
                // For collab videos the author line contains multiple runs (e.g.
                // "Inequality Media and Robert Reich"). Pick only the run whose
                // browseId matches channelId so the subscribed channel name is
                // shown instead of the joined collab string (#118).
                return extractText(text, matchingChannelId: channelId) ?? ""
            }()
            return Channel(id: channelId, title: channelTitle)
        }

        var tileDumped = false
        func walk(_ obj: Any, depth: Int = 0) {
            guard depth < 50 else {
                tubeLog.warning("parseSubscribedChannels: walk depth limit (50) reached — skipping subtree")
                return
            }
            if let dict = obj as? [String: Any] {
                if let tile = dict["tileRenderer"] as? [String: Any] {
                    // Dump the first tile to reveal its full structure
                    if !tileDumped {
                        tileDumped = true
                        if let data = try? JSONSerialization.data(withJSONObject: tile, options: [.sortedKeys]),
                           let str = String(data: data, encoding: .utf8) {
                            tubeLog.notice("parseSubscribedChannels first tileRenderer JSON: \(String(str.prefix(2000)), privacy: .public)")
                        }
                    }
                    if let channel = channelFromTile(tile) {
                        if seen.insert(channel.id).inserted {
                            channels.append(channel)
                        }
                    }
                    return
                }
                for value in dict.values { walk(value, depth: depth + 1) }
            } else if let arr = obj as? [Any] {
                for item in arr { walk(item, depth: depth + 1) }
            }
        }

        walk(json)
        // Sort alphabetically so the channel list is stable. Matches LocalSubscriptionStore.
        channels.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        tubeLog.notice("parseSubscribedChannels → \(channels.count, privacy: .public) unique channels")
        return channels
    }
}
