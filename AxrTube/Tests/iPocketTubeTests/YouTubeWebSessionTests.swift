import CryptoKit
import Foundation
import Testing
@testable import iPocketTubeCore

@Suite("Web sign-in for comments")
struct YouTubeWebSessionTests {
    @Test func authorizationMatchesWebsiteFormat() throws {
        let session = YouTubeWebSession(cookies: ["SAPISID": "abc", "__Secure-1PAPISID": "one", "__Secure-3PAPISID": "three"])
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let auth = try #require(session.authorization(now: now))
        func expected(_ secret: String) -> String {
            let digest = Insecure.SHA1.hash(data: Data("1700000000 \(secret) https://www.youtube.com".utf8))
            return "1700000000_" + digest.map { String(format: "%02x", $0) }.joined()
        }
        #expect(auth == "SAPISIDHASH \(expected("abc")) SAPISID1PHASH \(expected("one")) SAPISID3PHASH \(expected("three"))")
    }

    @Test func signedInNeedsSapisid() {
        #expect(!YouTubeWebSession(cookies: ["SID": "x"]).isSignedIn)
        #expect(YouTubeWebSession(cookies: ["__Secure-3PAPISID": "x"]).isSignedIn)
        #expect(YouTubeWebSession(cookies: ["__Secure-3PAPISID": "x"]).authorization() != nil)
    }

    @Test func cookieRotationIsMerged() {
        var session = YouTubeWebSession(cookies: ["SAPISID": "a", "__Secure-1PSIDTS": "old"])
        let changed = session.merge(
            setCookieHeaders: ["Set-Cookie": "__Secure-1PSIDTS=new; Domain=.youtube.com; Path=/; Secure"],
            url: URL(string: "https://www.youtube.com/youtubei/v1/next")!
        )
        #expect(changed)
        #expect(session.cookies["__Secure-1PSIDTS"] == "new")
        #expect(session.cookies["SAPISID"] == "a")
    }

    @Test func findsCommentsTokenInNextResponse() {
        let json: [String: Any] = ["engagementPanels": [
            ["engagementPanelSectionListRenderer": ["panelIdentifier": "engagement-panel-structured-description", "content": [:]]],
            ["engagementPanelSectionListRenderer": [
                "panelIdentifier": "engagement-panel-comments-section",
                "content": ["sectionListRenderer": ["contents": [["continuationItemRenderer": [
                    "continuationEndpoint": ["continuationCommand": ["token": "TOKEN"]]]]]]],
            ]],
        ]]
        #expect(CommentsPageParser.firstCommentsContinuation(in: json) == "TOKEN")
    }
}
