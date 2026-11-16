import Foundation
import os

/// InnerTube calls on www.youtube.com with the web sign-in: comments,
/// comment actions and the notification bell.
public actor YouTubeWebClient {
    public static let shared = YouTubeWebClient()

    public enum Failure: Error, Equatable {
        case notSignedIn
        case http(Int)
        case decoding
    }

    /// Desktop Safari: the website client version below expects a browser.
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Safari/605.1.15"
    static let clientName = "WEB"
    static let clientVersion = InnerTubeClients.Web.version

    private(set) var session: YouTubeWebSession?
    /// Persists cookie rotations (Keychain lives in the app target).
    private var persist: (@Sendable (YouTubeWebSession?) -> Void)?
    private let http: URLSession
    private let log = Logger(subsystem: "com.void.ipockettube.app", category: "WebComments")

    public init(configuration: URLSessionConfiguration = .ephemeral) {
        let config = configuration
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 25
        http = URLSession(configuration: config)
    }

    public func configure(session: YouTubeWebSession?, persist: @escaping @Sendable (YouTubeWebSession?) -> Void) {
        self.session = session
        self.persist = persist
    }

    public func setSession(_ session: YouTubeWebSession?) {
        self.session = session
        persist?(session)
    }

    public var isSignedIn: Bool { session?.isSignedIn ?? false }

    static func context(hl: String = "ru") -> [String: Any] {
        ["client": ["clientName": clientName, "clientVersion": clientVersion, "hl": hl, "gl": "US"]]
    }

    /// POST /youtubei/v1/<endpoint> as the signed-in website.
    public func post(_ endpoint: String, body: [String: Any]) async throws -> [String: Any] {
        guard let session, session.isSignedIn, let auth = session.authorization(),
              let url = URL(string: "https://www.youtube.com/youtubei/v1/\(endpoint)?prettyPrint=false") else {
            throw Failure.notSignedIn
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
        request.setValue("https://www.youtube.com", forHTTPHeaderField: "X-Origin")
        request.setValue("https://www.youtube.com/", forHTTPHeaderField: "Referer")
        request.setValue(auth, forHTTPHeaderField: "Authorization")
        request.setValue("0", forHTTPHeaderField: "X-Goog-AuthUser")
        request.setValue("1", forHTTPHeaderField: "X-YouTube-Client-Name")
        request.setValue(Self.clientVersion, forHTTPHeaderField: "X-YouTube-Client-Version")
        request.setValue("true", forHTTPHeaderField: "X-YouTube-Bootstrap-Logged-In")
        request.setValue(session.cookieHeader, forHTTPHeaderField: "Cookie")
        var payload = body
        payload["context"] = Self.context()
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, response) = try await http.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { throw Failure.decoding }
        absorbCookies(httpResponse)
        guard (200..<300).contains(httpResponse.statusCode) else {
            log.error("[web] \(endpoint, privacy: .public) HTTP \(httpResponse.statusCode)")
            throw Failure.http(httpResponse.statusCode)
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure.decoding }
        return json
    }

    private func absorbCookies(_ response: HTTPURLResponse) {
        guard var current = session, let url = response.url else { return }
        let headers = response.allHeaderFields.reduce(into: [String: String]()) { result, pair in
            if let key = pair.key as? String, let value = pair.value as? String { result[key] = value }
        }
        if current.merge(setCookieHeaders: headers, url: url) {
            session = current
            persist?(current)
        }
    }

    // MARK: Verification

    public struct Capability: Equatable, Sendable {
        public var signedIn: Bool
        public var canComment: Bool
        public var accountName: String?
    }

    /// Checks on a real video that the website treats us as signed in and
    /// offers the comment box. Reads only.
    public func verify(videoId: String = "jNQXAC9IVRw") async throws -> Capability {
        let next = try await post("next", body: ["videoId": videoId])
        let loggedOut = (JSONWalk.first("loggedOut", in: next) as? Bool) ?? false
        guard let token = CommentsPageParser.firstCommentsContinuation(in: next) else {
            return Capability(signedIn: !loggedOut, canComment: false, accountName: nil)
        }
        let page = try await post("next", body: ["continuation": token])
        let canComment = JSONWalk.first("createCommentParams", in: page) != nil
        let name = (JSONWalk.first("authorText", in: JSONWalk.first("commentSimpleboxRenderer", in: page) ?? [:]) as? [String: Any])
            .flatMap { $0["simpleText"] as? String }
        return Capability(signedIn: !loggedOut, canComment: canComment, accountName: name)
    }
}

/// Small recursive lookups over InnerTube JSON.
enum JSONWalk {
    static func first(_ key: String, in object: Any, depth: Int = 0) -> Any? {
        guard depth < 60 else { return nil }
        if let dict = object as? [String: Any] {
            if let value = dict[key] { return value }
            for value in dict.values { if let hit = first(key, in: value, depth: depth + 1) { return hit } }
        } else if let array = object as? [Any] {
            for value in array { if let hit = first(key, in: value, depth: depth + 1) { return hit } }
        }
        return nil
    }

    static func all(_ key: String, in object: Any, depth: Int = 0, into result: inout [Any]) {
        guard depth < 60 else { return }
        if let dict = object as? [String: Any] {
            if let value = dict[key] { result.append(value) }
            for value in dict.values { all(key, in: value, depth: depth + 1, into: &result) }
        } else if let array = object as? [Any] {
            for value in array { all(key, in: value, depth: depth + 1, into: &result) }
        }
    }
}

extension CommentsPageParser {
    /// Token of the comments section in a /next response (by panel id).
    static func firstCommentsContinuation(in json: [String: Any]) -> String? {
        guard let panels = json["engagementPanels"] as? [[String: Any]] else { return nil }
        for panel in panels {
            guard let renderer = panel["engagementPanelSectionListRenderer"] as? [String: Any],
                  (renderer["panelIdentifier"] as? String ?? "").lowercased().contains("comment"),
                  let content = renderer["content"] else { continue }
            var commands: [Any] = []
            JSONWalk.all("continuationCommand", in: content, into: &commands)
            if let token = commands.compactMap({ ($0 as? [String: Any])?["token"] as? String }).first {
                return token
            }
        }
        return nil
    }
}
