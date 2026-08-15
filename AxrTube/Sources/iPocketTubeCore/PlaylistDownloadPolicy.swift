// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

public enum PlaylistMediaSource: Equatable, Sendable {
    case hls(URL)
    case file(URL)
}

/// Deterministic source choice shared by production and tests. HLS is first
/// because AVFoundation can persist its selected renditions as one offline
/// asset. A muxed file is the portable fallback used by Brave Playlist too.
public enum PlaylistDownloadPolicy {
    public static func source(hlsURL: URL?, muxedFileURL: URL?) -> PlaylistMediaSource? {
        if let hlsURL { return .hls(hlsURL) }
        if let muxedFileURL { return .file(muxedFileURL) }
        return nil
    }
}

public struct PlaylistTaskIdentity: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        case hls
        case file
    }

    public let kind: Kind
    public let videoID: String

    public init(kind: Kind, videoID: String) {
        self.kind = kind
        self.videoID = videoID
    }

    public var taskDescription: String { "\(kind.rawValue)|\(videoID)" }

    public init?(taskDescription: String?) {
        guard let taskDescription else { return nil }
        let pieces = taskDescription.split(separator: "|", maxSplits: 1)
        guard pieces.count == 2,
              let kind = Kind(rawValue: String(pieces[0])),
              !pieces[1].isEmpty else { return nil }
        self.kind = kind
        self.videoID = String(pieces[1])
    }
}
