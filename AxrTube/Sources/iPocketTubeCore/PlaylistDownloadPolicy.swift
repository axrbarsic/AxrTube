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
    public static func shouldYieldToPlayback(preparing: Bool, waitingForBuffer: Bool) -> Bool {
        preparing || waitingForBuffer
    }

    public static let userFacingFailureMessage =
        "Не удалось продолжить загрузку видео. Проверьте сеть и повторите попытку."

    public static func source(hlsURL: URL?, muxedFileURL: URL?) -> PlaylistMediaSource? {
        if let hlsURL { return .hls(hlsURL) }
        if let muxedFileURL { return .file(muxedFileURL) }
        return nil
    }

    /// Request shape used by Brave Playlist for direct media files. Callers
    /// inject the session ID so production stays unique and tests deterministic.
    public static func fileRequest(
        url: URL,
        userAgent: String,
        playbackSessionID: String
    ) -> URLRequest {
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 60
        )
        request.addValue("bytes=0-", forHTTPHeaderField: "Range")
        request.addValue(playbackSessionID, forHTTPHeaderField: "X-Playback-Session-Id")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        return request
    }

    public static func acceptsHTTPStatus(_ statusCode: Int) -> Bool {
        statusCode == 200 || statusCode == 206
    }

    public static func retryDelay(errorCode: Int, httpStatus: Int?, attempt: Int) -> TimeInterval? {
        guard (0..<5).contains(attempt) else { return nil }
        let transient = [NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost,
                         NSURLErrorNotConnectedToInternet, NSURLErrorCannotConnectToHost,
                         NSURLErrorDNSLookupFailed].contains(errorCode)
        guard transient || httpStatus == 408 || httpStatus == 429
                || (httpStatus.map { (500...599).contains($0) } ?? false) else { return nil }
        return min(120, 5 * pow(2, Double(attempt)))
    }

    /// Converts background URLSession failures into stable product copy. Raw
    /// NSError domains and numeric codes are diagnostics, not user guidance.
    public static func failureMessage(urlErrorCode: Int, httpStatus: Int?) -> String {
        if httpStatus == 401 || httpStatus == 403 || urlErrorCode == NSURLErrorBadServerResponse {
            return "Источник отклонил загрузку видео. Нажмите «Повторить», чтобы получить новую ссылку."
        }
        if urlErrorCode == NSURLErrorNotConnectedToInternet
            || urlErrorCode == NSURLErrorNetworkConnectionLost
            || urlErrorCode == NSURLErrorTimedOut {
            return "Соединение прервано. Проверьте сеть и нажмите «Повторить»."
        }
        return userFacingFailureMessage
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
