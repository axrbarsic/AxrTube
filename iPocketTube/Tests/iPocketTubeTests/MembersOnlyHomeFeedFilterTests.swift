import Foundation
import Testing
@testable import iPocketTubeCore

// MARK: - MembersOnlyHomeFeedFilterTests
//
// Regression tests for task #227: members-only videos must be dropped from the
// home/subs/history feed by the `parseTileRenderer` function before they reach
// the UI. Without the fix, users would see a "Join this channel" error when
// tapping a video that should never have appeared in the feed.
//
// `parseTileRenderer` is private, so these tests validate the three detection
// signals via the public `parseVideoGroup` entry point, using minimal synthetic
// InnerTube JSON that mirrors what the TVHTML5 client returns.
//
// Detection signals implemented:
//  1. `thumbnailOverlayMembershipBadgeRenderer` present in header overlays
//  2. `metadataBadgeRenderer` with MEMBERS_ONLY icon type in tileMetadata.badges
//  3. "Members only" text in a secondary tileMetadata line item

@Suite("Members-only tile filter in parseTileRenderer — task #227 regression")
struct MembersOnlyHomeFeedFilterTests {

    // MARK: - Helpers

    private let api = InnerTubeAPI()

    /// Builds a minimal TVHTML5 `tileRenderer` dict with the given overlay.
    private func makeTileRendererDict(
        videoId: String,
        extraOverlays: [[String: Any]] = [],
        badges: [[String: Any]] = [],
        secondaryLineText: String? = nil
    ) -> [String: Any] {
        var overlays: [[String: Any]] = [
            // Standard time status overlay (always present)
            ["thumbnailOverlayTimeStatusRenderer": [
                "text": ["simpleText": "8:34"],
                "style": "DEFAULT"
            ]]
        ]
        overlays.append(contentsOf: extraOverlays)

        var secondaryItems: [[String: Any]] = [
            // Typical secondary item — views count
            ["lineItemRenderer": ["text": ["simpleText": "1.2M views"]]]
        ]
        if let text = secondaryLineText {
            secondaryItems.append(["lineItemRenderer": ["text": ["simpleText": text]]])
        }

        var metadataDict: [String: Any] = [
            "tileMetadataRenderer": [
                "title": ["simpleText": "Test Video"],
                "lines": [
                    // Line 0: channel name
                    ["lineRenderer": ["items": [
                        ["lineItemRenderer": ["text": ["simpleText": "Test Channel"]]]
                    ]]],
                    // Line 1: secondary info (views, date, or members-only text)
                    ["lineRenderer": ["items": secondaryItems]]
                ]
            ]
        ]
        if !badges.isEmpty {
            var tileMetaRenderer = (metadataDict["tileMetadataRenderer"] as! [String: Any])
            tileMetaRenderer["badges"] = badges
            metadataDict["tileMetadataRenderer"] = tileMetaRenderer
        }

        return [
            "contentType": "TILE_CONTENT_TYPE_VIDEO",
            "style": "TILE_STYLE_YTLR_DEFAULT",
            "contentId": videoId,
            "onSelectCommand": ["watchEndpoint": ["videoId": videoId]],
            "header": [
                "tileHeaderRenderer": [
                    "thumbnail": ["thumbnails": [["url": "https://example.com/thumb.jpg", "width": 1280, "height": 720]]],
                    "thumbnailOverlays": overlays
                ]
            ],
            "metadata": metadataDict
        ]
    }

    /// Wraps a single tile into a minimal TVHTML5 `/browse` response.
    private func makeBrowseResponse(tiles: [[String: Any]]) -> [String: Any] {
        let items: [[String: Any]] = tiles.map { tile in
            ["tileRenderer": tile]
        }
        return [
            "header": ["feedTabbedHeaderRenderer": ["title": ["simpleText": "Home"]]],
            "contents": [
                "tvBrowseRenderer": [
                    "content": [
                        "tvSurfaceContentRenderer": [
                            "content": [
                                "sectionListRenderer": [
                                    "contents": [
                                        ["shelfRenderer": [
                                            "title": ["simpleText": "Home"],
                                            "content": ["horizontalListRenderer": ["items": items]]
                                        ]]
                                    ]
                                ]
                            ]
                        ]
                    ]
                ]
            ]
        ]
    }

    // MARK: - Control: regular video passes through

    @Test("Regular video tile is included in the feed")
    func regularVideoIsIncluded() async throws {
        let tile = makeTileRendererDict(videoId: "regularVideo1")
        let response = makeBrowseResponse(tiles: [tile])
        let group = try await api.parseVideoGroup(from: response, title: "Home")
        #expect(group.videos.contains(where: { $0.id == "regularVideo1" }),
                "A regular tile must be included in the home feed")
    }

    // MARK: - Signal 1: thumbnailOverlayMembershipBadgeRenderer

    @Test("Signal 1: thumbnailOverlayMembershipBadgeRenderer drops the tile")
    func membershipOverlayDropsTile() async throws {
        let membershipOverlay: [String: Any] = [
            "thumbnailOverlayMembershipBadgeRenderer": [
                "text": ["simpleText": "Members only"]
            ]
        ]
        let tile = makeTileRendererDict(videoId: "membersVideo1", extraOverlays: [membershipOverlay])
        let response = makeBrowseResponse(tiles: [tile])
        let group = try await api.parseVideoGroup(from: response, title: "Home")
        #expect(!group.videos.contains(where: { $0.id == "membersVideo1" }),
                "Signal 1: tile with thumbnailOverlayMembershipBadgeRenderer must be dropped")
    }

    // MARK: - Signal 2: metadataBadgeRenderer MEMBERS_ONLY icon type

    @Test("Signal 2: metadataBadgeRenderer with MEMBERS_ONLY icon type drops the tile")
    func membersBadgeIconDropsTile() async throws {
        let badge: [String: Any] = [
            "metadataBadgeRenderer": [
                "icon": ["iconType": "MEMBERS_ONLY"],
                "style": "BADGE_STYLE_TYPE_SIMPLE",
                "label": "Members only"
            ]
        ]
        let tile = makeTileRendererDict(videoId: "membersVideo2", badges: [badge])
        let response = makeBrowseResponse(tiles: [tile])
        let group = try await api.parseVideoGroup(from: response, title: "Home")
        #expect(!group.videos.contains(where: { $0.id == "membersVideo2" }),
                "Signal 2: tile with MEMBERS_ONLY badge icon type must be dropped")
    }

    @Test("Signal 2: metadataBadgeRenderer with MEMBERS_ONLY_BADGE icon prefix drops the tile")
    func membersBadgeIconPrefixDropsTile() async throws {
        let badge: [String: Any] = [
            "metadataBadgeRenderer": [
                "icon": ["iconType": "MEMBERS_ONLY_BADGE"],
                "label": ""
            ]
        ]
        let tile = makeTileRendererDict(videoId: "membersVideo3", badges: [badge])
        let response = makeBrowseResponse(tiles: [tile])
        let group = try await api.parseVideoGroup(from: response, title: "Home")
        #expect(!group.videos.contains(where: { $0.id == "membersVideo3" }),
                "Signal 2: icon type starting with MEMBERS must drop the tile")
    }

    @Test("Signal 2: metadataBadgeRenderer with 'member' label (case-insensitive) drops the tile")
    func membersBadgeLabelDropsTile() async throws {
        let badge: [String: Any] = [
            "metadataBadgeRenderer": [
                "icon": ["iconType": "UNKNOWN_ICON"],
                "label": "Members only"
            ]
        ]
        let tile = makeTileRendererDict(videoId: "membersVideo4", badges: [badge])
        let response = makeBrowseResponse(tiles: [tile])
        let group = try await api.parseVideoGroup(from: response, title: "Home")
        #expect(!group.videos.contains(where: { $0.id == "membersVideo4" }),
                "Signal 2: badge label containing 'member' must drop the tile")
    }

    // MARK: - Signal 3: "Members only" text in secondary metadata line

    @Test("Signal 3: 'Members only' text in secondary metadata line drops the tile")
    func membersOnlyLineTextDropsTile() async throws {
        let tile = makeTileRendererDict(videoId: "membersVideo5", secondaryLineText: "Members only")
        let response = makeBrowseResponse(tiles: [tile])
        let group = try await api.parseVideoGroup(from: response, title: "Home")
        #expect(!group.videos.contains(where: { $0.id == "membersVideo5" }),
                "Signal 3: 'Members only' text in secondary line must drop the tile")
    }

    @Test("Signal 3: 'members only' lowercase text in secondary line drops the tile")
    func membersOnlyLineLowercaseDropsTile() async throws {
        let tile = makeTileRendererDict(videoId: "membersVideo6", secondaryLineText: "members only")
        let response = makeBrowseResponse(tiles: [tile])
        let group = try await api.parseVideoGroup(from: response, title: "Home")
        #expect(!group.videos.contains(where: { $0.id == "membersVideo6" }),
                "Signal 3: lowercased 'members only' text must drop the tile")
    }

    // MARK: - Non-member badge does not drop the tile

    @Test("Non-member badge icon type does NOT drop a regular tile")
    func nonMemberBadgeIsAllowed() async throws {
        let badge: [String: Any] = [
            "metadataBadgeRenderer": [
                "icon": ["iconType": "CHECK_CIRCLE_THICK"],
                "label": "Verified"
            ]
        ]
        let tile = makeTileRendererDict(videoId: "verifiedChannel1", badges: [badge])
        let response = makeBrowseResponse(tiles: [tile])
        let group = try await api.parseVideoGroup(from: response, title: "Home")
        #expect(group.videos.contains(where: { $0.id == "verifiedChannel1" }),
                "Non-member badge (e.g. Verified) must NOT drop the tile")
    }
}
