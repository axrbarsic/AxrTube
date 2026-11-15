import Foundation
import Testing
@testable import iPocketTubeCore

@Suite("Comments paging parser")
struct CommentsPageParserTests {
    private func comment(_ id: String) -> iPocketTubeCore.Comment {
        iPocketTubeCore.Comment(id: id, author: id, authorAvatarURL: nil, text: id, likeCount: "", publishedTime: "", isLiked: false)
    }

    private func thread(_ id: String, replyToken: String? = nil) -> [String: Any] {
        var thread: [String: Any] = ["commentViewModel": ["commentViewModel": ["commentId": id]]]
        if let replyToken {
            thread["replies"] = ["commentRepliesRenderer": [
                "contents": [["continuationItemRenderer": ["continuationEndpoint": ["continuationCommand": ["token": replyToken]]]]],
                "viewReplies": ["buttonRenderer": ["text": ["simpleText": "3 ответа"]]],
            ]]
        }
        return ["commentThreadRenderer": thread]
    }

    private let text: ([String: Any]) -> String? = { $0["simpleText"] as? String }

    @Test func ordersByThreadsAndReadsCursors() {
        let json: [String: Any] = ["onResponseReceivedEndpoints": [[
            "reloadContinuationItemsCommand": ["continuationItems": [
                ["commentsHeaderRenderer": ["sortMenu": ["sortFilterSubMenuRenderer": ["subMenuItems": [
                    ["title": "Популярные", "serviceEndpoint": ["continuationCommand": ["token": "top"]]],
                    ["title": "Новые", "serviceEndpoint": ["continuationCommand": ["token": "new"]]],
                ]]]]],
                thread("b", replyToken: "rb"),
                thread("a"),
                ["continuationItemRenderer": ["continuationEndpoint": ["continuationCommand": ["token": "page2"]]]],
            ]],
        ]]]
        let page = CommentsPageParser.page(from: json, comments: [comment("a"), comment("b")], text: text)
        #expect(page.comments.map(\.id) == ["b", "a"])
        #expect(page.nextToken == "page2")
        #expect(page.sortOptions.map(\.title) == ["Популярные", "Новые"])
        #expect(page.replyTokens == ["b": "rb"])
        #expect(page.replyLabels["b"] == "3 ответа")
    }

    @Test func replyCursorIsNotThePageCursor() {
        let json: [String: Any] = ["onResponseReceivedEndpoints": [[
            "appendContinuationItemsAction": ["continuationItems": [thread("x", replyToken: "rx")]],
        ]]]
        let page = CommentsPageParser.page(from: json, comments: [comment("x")], text: text)
        #expect(page.nextToken == nil)
        #expect(page.replyTokens["x"] == "rx")
    }

    @Test func replyPageUsesShowMoreButton() {
        let json: [String: Any] = ["onResponseReceivedEndpoints": [[
            "appendContinuationItemsAction": ["continuationItems": [
                ["commentViewModel": ["commentId": "r1"]],
                ["continuationItemRenderer": ["button": ["buttonRenderer": ["command": ["continuationCommand": ["token": "more"]]]]]],
            ]],
        ]]]
        let page = CommentsPageParser.page(from: json, comments: [comment("r1")], text: text)
        #expect(page.comments.map(\.id) == ["r1"])
        #expect(page.nextToken == "more")
    }
}

@Suite("Watch owner parser")
struct WatchOwnerParserTests {
    @Test func readsOwnerLikesAndSubscription() {
        let json: [String: Any] = ["contents": ["twoColumnWatchNextResults": ["results": ["results": ["contents": [
            ["videoPrimaryInfoRenderer": ["videoActions": ["menuRenderer": ["topLevelButtons": [[
                "segmentedLikeDislikeButtonViewModel": ["likeButtonViewModel": ["likeButtonViewModel": [
                    "toggleButtonViewModel": ["toggleButtonViewModel": [
                        "defaultButtonViewModel": ["buttonViewModel": ["title": "12 тыс."]],
                        "toggledButtonViewModel": ["buttonViewModel": ["title": "12 тыс. +1"]],
                    ]],
                ]]],
            ]]]]]],
            ["videoSecondaryInfoRenderer": [
                "owner": ["videoOwnerRenderer": [
                    "title": ["simpleText": "Канал"],
                    "subscriberCountText": ["simpleText": "1,2 млн подписчиков"],
                    "thumbnail": ["thumbnails": [["url": "//yt3.ggpht.com/a"], ["url": "//yt3.ggpht.com/b"]]],
                    "navigationEndpoint": ["browseEndpoint": ["browseId": "UC1"]],
                ]],
                "subscribeButton": ["subscribeButtonRenderer": ["subscribed": true]],
            ]],
        ]]]]]]
        let info = WatchOwnerParser.parse(json, text: { $0["simpleText"] as? String })
        #expect(info.channelTitle == "Канал")
        #expect(info.subscriberText == "1,2 млн подписчиков")
        #expect(info.avatarURL?.absoluteString == "https://yt3.ggpht.com/b")
        #expect(info.channelId == "UC1")
        #expect(info.likeCountText == "12 тыс.")
        #expect(info.isSubscribed == true)
    }
}
