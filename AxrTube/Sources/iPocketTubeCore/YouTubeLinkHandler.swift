import Foundation

// MARK: - YouTubeLinkHandler

/// Extracts a YouTube video ID from various YouTube URL formats.
///
/// Supported formats:
/// - `https://www.youtube.com/watch?v=VIDEO_ID`
/// - `https://youtu.be/VIDEO_ID`
/// - `https://www.youtube.com/shorts/VIDEO_ID`
/// - `https://www.youtube.com/v/VIDEO_ID`
/// - `https://m.youtube.com/watch?v=VIDEO_ID`
/// - `https://music.youtube.com/watch?v=VIDEO_ID`
/// - `youtube://watch?v=VIDEO_ID`
/// - `youtube://VIDEO_ID`
/// - `vnd.youtube://VIDEO_ID`
/// - `vnd.youtube:VIDEO_ID`
public enum YouTubeLinkHandler {

    /// Returns the video ID embedded in `url`, or `nil` if it cannot be extracted.
    public static func videoID(from url: URL) -> String? {
        let scheme = url.scheme?.lowercased() ?? ""

        // Custom deep-link schemes: youtube:// and vnd.youtube://
        if scheme == "youtube" || scheme == "vnd.youtube" {
            return videoIDFromYouTubeScheme(url)
        }

        // Web URLs
        guard scheme == "https" || scheme == "http" else { return nil }
        guard let host = url.host?.lowercased() else { return nil }
        guard host == "youtube.com" || host == "www.youtube.com" || host == "m.youtube.com"
                || host == "youtu.be" || host == "music.youtube.com" else {
            return nil
        }

        let path = url.path

        // youtu.be/VIDEO_ID
        if host == "youtu.be" {
            let id = String(path.dropFirst()) // remove leading /
            return validID(id)
        }

        // /shorts/VIDEO_ID or /v/VIDEO_ID
        let pathComponents = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if pathComponents.count >= 2 {
            let segment = pathComponents[0].lowercased()
            if segment == "shorts" || segment == "v" {
                return validID(pathComponents[1])
            }
        }

        // /watch?v=VIDEO_ID
        if path.lowercased() == "/watch" || path.lowercased().hasPrefix("/watch") {
            guard let v = queryParam("v", in: url) else { return nil }
            return validID(v)
        }

        return nil
    }

    /// Returns `true` if `url` is a YouTube URL that iPocketTube can handle.
    public static func isYouTubeURL(_ url: URL) -> Bool {
        videoID(from: url) != nil
    }

    // MARK: - Private helpers

    private static func videoIDFromYouTubeScheme(_ url: URL) -> String? {
        // youtube://watch?v=VIDEO_ID  or  vnd.youtube://watch?v=VIDEO_ID
        if let v = queryParam("v", in: url), !v.isEmpty {
            return validID(v)
        }
        // youtube://VIDEO_ID  or  vnd.youtube://VIDEO_ID  (host is the video ID)
        let host = url.host ?? ""
        if !host.isEmpty && host.lowercased() != "watch" {
            return validID(host)
        }
        // vnd.youtube:VIDEO_ID (opaque URL — no authority component)
        // URLComponents parses the path as the "part after the scheme:"
        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            let candidate = components.path
                .split(separator: "?").first
                .map(String.init) ?? components.path
            return validID(candidate)
        }
        return nil
    }

    private static func queryParam(_ name: String, in url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        return components.queryItems?.first(where: { $0.name == name })?.value
    }

    /// YouTube video IDs are exactly 11 URL-safe base64 characters.
    private static func validID(_ candidate: String) -> String? {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count == 11 else { return nil }
        let allowedChars = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        guard trimmed.unicodeScalars.allSatisfy({ allowedChars.contains($0) }) else { return nil }
        return trimmed
    }
}
