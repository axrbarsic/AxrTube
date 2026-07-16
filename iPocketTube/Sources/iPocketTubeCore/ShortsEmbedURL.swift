import Foundation

/// Pure `videoId` → YouTube IFrame embed `URL` construction for the Shorts TOS
/// embed player (`ShortsEmbedPlayerViewModel`, Task 4).
///
/// Mirrors `ShortsEmbedJS.embedURL`/`htmlWrapper` — the Task 1 spike's
/// `iPocketTube`-local, spike-only copies. From Task 4 onward
/// `ShortsEmbedPlayerViewModel` uses these `iPocketTubeCore` versions instead,
/// so the URL/HTML construction is unit-testable without a `WKWebView` (same
/// pattern as `parseHLSMasterManifest` in `HLSManifestParser.swift`).
public enum ShortsEmbedURL {

    /// Builds `https://www.youtube.com/embed/{videoId}?...` with the query items
    /// required for an autoplaying, muted, inline, controls-visible Shorts embed.
    /// `SwipeGestureOverlay` lets touches pass through to this native chrome so
    /// YouTube's own play/pause and top-right controls remain reachable.
    public static func embedURL(videoId: String, startTime: Double = 0) -> URL {
        var comps = URLComponents(string: "https://www.youtube.com/embed/\(videoId)")!
        comps.queryItems = [
            URLQueryItem(name: "autoplay",       value: "1"),
            URLQueryItem(name: "mute",           value: "1"),
            URLQueryItem(name: "controls",       value: "0"),
            URLQueryItem(name: "playsinline",    value: "1"),
            URLQueryItem(name: "rel",            value: "0"),
            URLQueryItem(name: "iv_load_policy", value: "3"),
            URLQueryItem(name: "start",          value: "\(Int(startTime))"),
            URLQueryItem(name: "origin",         value: "https://www.example.com"),
        ]
        return comps.url!
    }

    /// Extracts the `videoId` back out of `embedURL(videoId:)`'s output, e.g.
    /// `https://www.youtube.com/embed/abc123?autoplay=1...` → `"abc123"`. Used to
    /// detect stale "ready" messages from an abandoned `loadShort(video:)` call
    /// (see `ShortsEmbedPlayerViewModel+WebBridge.swift`'s "ready" case, #275) —
    /// the embed URL is the only signal available that ties a JS bridge message
    /// back to the specific video it was loading.
    public static func videoId(fromEmbedURL url: URL) -> String? {
        let path = url.path
        guard let range = path.range(of: "/embed/") else { return nil }
        let id = path[range.upperBound...]
        return id.isEmpty ? nil : String(id)
    }

    /// Wraps an embed URL in the `<iframe id="yt">` HTML page used by
    /// `ShortsEmbedPlayerViewModel.start()`/`loadShort(video:)`.
    public static func htmlWrapper(embedURL: URL) -> String {
        """
        <!DOCTYPE html>
        <html>
        <head>
            <meta name="viewport" content="width=device-width,initial-scale=1">
            <style>
                html,body,iframe{margin:0;padding:0;border:0;width:100%;height:100%;background:#000}
                iframe{position:absolute;top:0;left:0}
            </style>
        </head>
        <body>
            <iframe id="yt"
                src="\(embedURL.absoluteString)"
                frameborder="0"
                allow="autoplay; encrypted-media; fullscreen"
                allowfullscreen>
            </iframe>
        </body>
        </html>
        """
    }
}
