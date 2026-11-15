import Foundation

/// One server-provided comment ordering ("Популярные", "Новые").
public struct CommentSortOption: Sendable, Hashable, Identifiable {
    public let title: String
    public let token: String
    public var id: String { token }
}

/// One page of comments or replies, in the order YouTube returned them.
public struct CommentsPage: Sendable {
    public var comments: [Comment]
    public var nextToken: String?
    public var sortOptions: [CommentSortOption]
    /// commentId → continuation token that loads its replies.
    public var replyTokens: [String: String]
    /// commentId → "12 ответов" label as sent by YouTube.
    public var replyLabels: [String: String]

    public static let empty = CommentsPage(comments: [], nextToken: nil, sortOptions: [], replyTokens: [:], replyLabels: [:])
}

extension InnerTubeAPI {
    /// First page of top-level comments plus sort options and reply cursors.
    public func fetchCommentsPage(videoId: String) async throws -> CommentsPage {
        var body = makeBody(client: webClientContext)
        body["videoId"] = videoId
        let nextData = try await post(endpoint: "next", body: body)
        guard let token = parseCommentsContinuationToken(from: nextData) else { return .empty }
        return try await fetchCommentsPage(continuation: token)
    }

    /// A following page, a different sort order, or a reply thread.
    public func fetchCommentsPage(continuation: String) async throws -> CommentsPage {
        let data = try await post(endpoint: "next", body: makeBody(client: webClientContext, continuationToken: continuation))
        return CommentsPageParser.page(from: data, comments: parseComments(from: data), text: { self.extractText($0) })
    }
}

/// Pure response walker, separated from networking so it can be unit tested.
enum CommentsPageParser {
    static func page(
        from json: [String: Any],
        comments: [Comment],
        text: ([String: Any]) -> String?
    ) -> CommentsPage {
        var order: [String] = []
        var replyTokens: [String: String] = [:]
        var replyLabels: [String: String] = [:]
        var sortOptions: [CommentSortOption] = []
        var nextToken: String?

        func token(in item: [String: Any]) -> String? {
            let endpoint = item["continuationEndpoint"] as? [String: Any]
            let button = ((item["button"] as? [String: Any])?["buttonRenderer"] as? [String: Any])?["command"] as? [String: Any]
            let command = (endpoint ?? button)?["continuationCommand"] as? [String: Any]
            return command?["token"] as? String
        }

        func walk(_ object: Any, insideThread: Bool, depth: Int) {
            guard depth < 60 else { return }
            if let array = object as? [Any] {
                array.forEach { walk($0, insideThread: insideThread, depth: depth + 1) }
                return
            }
            guard let dict = object as? [String: Any] else { return }

            if let menu = dict["sortFilterSubMenuRenderer"] as? [String: Any],
               let items = menu["subMenuItems"] as? [[String: Any]], sortOptions.isEmpty {
                sortOptions = items.compactMap { item in
                    let command = (item["serviceEndpoint"] as? [String: Any])?["continuationCommand"] as? [String: Any]
                    guard let title = item["title"] as? String, let token = command?["token"] as? String else { return nil }
                    return CommentSortOption(title: title, token: token)
                }
            }
            if let thread = dict["commentThreadRenderer"] as? [String: Any] {
                var threadID: String?
                if let model = (thread["commentViewModel"] as? [String: Any])?["commentViewModel"] as? [String: Any] {
                    threadID = model["commentId"] as? String
                } else if let legacy = (thread["comment"] as? [String: Any])?["commentRenderer"] as? [String: Any] {
                    threadID = legacy["commentId"] as? String
                }
                if let id = threadID {
                    order.append(id)
                    let replies = (thread["replies"] as? [String: Any])?["commentRepliesRenderer"] as? [String: Any]
                    if let contents = replies?["contents"] as? [[String: Any]],
                       let item = contents.lazy.compactMap({ $0["continuationItemRenderer"] as? [String: Any] }).first,
                       let replyToken = token(in: item) {
                        replyTokens[id] = replyToken
                    }
                    if let button = (replies?["viewReplies"] as? [String: Any])?["buttonRenderer"] as? [String: Any],
                       let label = (button["text"] as? [String: Any]).flatMap(text) {
                        replyLabels[id] = label
                    }
                }
                return
            }
            if let model = dict["commentViewModel"] as? [String: Any], let id = model["commentId"] as? String {
                order.append(id)
            }
            if let item = dict["continuationItemRenderer"] as? [String: Any], !insideThread, let next = token(in: item) {
                nextToken = next
            }
            for value in dict.values { walk(value, insideThread: insideThread, depth: depth + 1) }
        }

        walk(json["onResponseReceivedEndpoints"] ?? [], insideThread: false, depth: 0)

        // Entity mutations are not guaranteed to be in display order.
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let ordered = comments.enumerated().sorted { lhs, rhs in
            switch (rank[lhs.element.id], rank[rhs.element.id]) {
            case let (l?, r?): return l < r
            case (_?, nil): return true
            case (nil, _?): return false
            default: return lhs.offset < rhs.offset
            }
        }.map(\.element)
        var seen = Set<String>()
        return CommentsPage(
            comments: ordered.filter { seen.insert($0.id).inserted },
            nextToken: nextToken,
            sortOptions: sortOptions,
            replyTokens: replyTokens,
            replyLabels: replyLabels
        )
    }
}
