#if DEBUG
import Foundation

// Read-only diagnostic for the comments feature: which signed-in request
// shapes YouTube accepts for this account, and what the responses contain.
// Sends nothing but fetches; output has strings truncated (no full tokens).
extension InnerTubeAPI {
    public func commentsCapabilityProbe(videoId: String) async -> Data {
        var report: [String: Any] = [
            "videoId": videoId, "hasBearer": authToken != nil, "hasSAPISID": sapisid != nil,
            "date": ISO8601DateFormatter().string(from: Date()),
        ]
        struct Mode { let label, host, clientName, clientVersion, nameID, auth: String }
        let web = InnerTubeClients.Web.self
        let modes = [
            Mode(label: "web-bearer-www", host: "https://www.youtube.com", clientName: web.name, clientVersion: web.version, nameID: web.nameID, auth: "bearer"),
            Mode(label: "web-sapisid-www", host: "https://www.youtube.com", clientName: web.name, clientVersion: web.version, nameID: web.nameID, auth: "sapisid"),
            Mode(label: "web-bearer-googleapis", host: "https://youtubei.googleapis.com", clientName: web.name, clientVersion: web.version, nameID: web.nameID, auth: "bearer"),
            Mode(label: "mweb-bearer-www", host: "https://m.youtube.com", clientName: "MWEB", clientVersion: InnerTubeClients.MWEB.version, nameID: "2", auth: "bearer"),
            Mode(label: "tv-bearer-googleapis", host: "https://youtubei.googleapis.com", clientName: "TVHTML5", clientVersion: InnerTubeClients.TV.version, nameID: InnerTubeClients.TV.nameID, auth: "bearer"),
            Mode(label: "ios-bearer-googleapis", host: "https://youtubei.googleapis.com", clientName: "IOS", clientVersion: InnerTubeClients.iOS.version, nameID: "5", auth: "bearer"),
            Mode(label: "android-bearer-googleapis", host: "https://youtubei.googleapis.com", clientName: "ANDROID", clientVersion: InnerTubeClients.Android.version, nameID: "3", auth: "bearer"),
        ]
        var results: [[String: Any]] = []
        for mode in modes {
            var entry: [String: Any] = ["mode": mode.label]
            func call(_ endpoint: String, _ extra: [String: Any]) async -> (Int, [String: Any]?) {
                guard let url = URL(string: "\(mode.host)/youtubei/v1/\(endpoint)?prettyPrint=false") else { return (-1, nil) }
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue(mode.nameID, forHTTPHeaderField: "X-YouTube-Client-Name")
                request.setValue(mode.clientVersion, forHTTPHeaderField: "X-YouTube-Client-Version")
                if mode.host.contains("youtube.com") {
                    request.setValue(mode.host, forHTTPHeaderField: "Origin")
                    request.setValue(InnerTubeClients.Web.userAgent, forHTTPHeaderField: "User-Agent")
                }
                if mode.auth == "bearer", let token = authToken {
                    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                    request.setValue("0", forHTTPHeaderField: "X-Goog-AuthUser")
                } else if mode.auth == "sapisid", let sid = sapisid {
                    request.setValue(InnerTubeAPI.sapisidhash(sapisid: sid), forHTTPHeaderField: "Authorization")
                    request.setValue("0", forHTTPHeaderField: "X-Goog-AuthUser")
                    request.setValue("https://www.youtube.com", forHTTPHeaderField: "X-Origin")
                    request.setValue("SAPISID=\(sid); __Secure-3PAPISID=\(sid)", forHTTPHeaderField: "Cookie")
                } else {
                    return (-2, nil)
                }
                var body = extra
                body["context"] = ["client": ["clientName": mode.clientName, "clientVersion": mode.clientVersion, "hl": "ru", "gl": "US"]]
                request.httpBody = try? JSONSerialization.data(withJSONObject: body)
                guard let (data, response) = try? await session.data(for: request) else { return (-3, nil) }
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                return (status, (try? JSONSerialization.jsonObject(with: data)) as? [String: Any])
            }
            let (nextStatus, next) = await call("next", ["videoId": videoId])
            entry["next.status"] = nextStatus
            if let next {
                entry["next.loggedOut"] = Self.probeFind("loggedOut", in: next) ?? "absent"
                entry["next.topKeys"] = next.keys.sorted()
                if let token = parseCommentsContinuationToken(from: next) {
                    let (status, page) = await call("next", ["continuation": token])
                    entry["comments.status"] = status
                    if let page {
                        entry["comments.keysOfInterest"] = Self.probeCount(
                            ["createCommentParams", "createReplyParams", "performCommentActionEndpoint", "commentViewModel",
                             "commentEntityPayload", "engagementToolbarSurfaceEntityPayload", "engagementToolbarStateEntityPayload",
                             "commentSurfaceEntityPayload", "commentSimpleboxRenderer", "updateCommentParams", "menuCommand",
                             "getCommentMenuEndpoint", "signInEndpoint", "likeCommand", "replyCommand", "avatarThumbnailUrl"],
                            in: page)
                        entry["comments.shape"] = Self.probeShape(page, depth: 0)
                    }
                } else {
                    entry["comments.status"] = "no continuation token"
                    entry["next.shape"] = Self.probeShape(next, depth: 6)
                }
            }
            let (unseenStatus, unseen) = await call("notification/get_unseen_count", [:])
            entry["unseen.status"] = unseenStatus
            if let unseen { entry["unseen.shape"] = Self.probeShape(unseen, depth: 4) }
            let (menuStatus, menu) = await call("notification/get_notification_menu", ["notificationsMenuRequestType": "NOTIFICATIONS_MENU_REQUEST_TYPE_INBOX"])
            entry["menu.status"] = menuStatus
            if let menu { entry["menu.shape"] = Self.probeShape(menu, depth: 0) }
            results.append(entry)
        }
        report["modes"] = results
        return (try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])) ?? Data()
    }

    static func probeFind(_ key: String, in object: Any, depth: Int = 0) -> Any? {
        guard depth < 40 else { return nil }
        if let dict = object as? [String: Any] {
            if let value = dict[key] { return value }
            for value in dict.values { if let hit = probeFind(key, in: value, depth: depth + 1) { return hit } }
        } else if let array = object as? [Any] {
            for value in array { if let hit = probeFind(key, in: value, depth: depth + 1) { return hit } }
        }
        return nil
    }

    static func probeCount(_ keys: [String], in object: Any) -> [String: Int] {
        var counts: [String: Int] = [:]
        func walk(_ object: Any, _ depth: Int) {
            guard depth < 60 else { return }
            if let dict = object as? [String: Any] {
                for (key, value) in dict {
                    if keys.contains(key) { counts[key, default: 0] += 1 }
                    walk(value, depth + 1)
                }
            } else if let array = object as? [Any] {
                array.forEach { walk($0, depth + 1) }
            }
        }
        walk(object, 0)
        return counts
    }

    /// Structure with strings cut to 28 characters and arrays to 3 items.
    static func probeShape(_ object: Any, depth: Int) -> Any {
        if depth > 30 { return "…" }
        if let dict = object as? [String: Any] {
            return dict.mapValues { probeShape($0, depth: depth + 1) }
        }
        if let array = object as? [Any] {
            var out = array.prefix(3).map { probeShape($0, depth: depth + 1) }
            if array.count > 3 { out.append("…+\(array.count - 3)") }
            return out
        }
        if let string = object as? String {
            return string.count > 28 ? String(string.prefix(28)) + "…(\(string.count))" : string
        }
        return object
    }
}
#endif
