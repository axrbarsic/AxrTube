import Foundation

// MARK: - HTMLVideoLinkExtractor

/// Extracts a YouTube-recognisable URL from raw HTML.
///
/// Strategies are tried in order; the first hit is returned:
///   1. `<meta property="og:url" content="…">`
///   2. `<link rel="canonical" href="…">`
///   3. First `<a href="…">` whose href contains "youtube.com" or "youtu.be"
///   4. `"url":"…"` inside a `<script type="application/ld+json">` block
///   5. YouTube embed iframe: `<iframe src="https://www.youtube.com/embed/VIDEO_ID">`
///
/// All parsing uses `NSRegularExpression` — no external HTML-parser dependency.
/// The result is always validated by `YouTubeLinkHandler.videoID(from:)` before
/// being returned to the caller.
public enum HTMLVideoLinkExtractor {

    // MARK: - Public API

    /// Scans `html` for a URL that `YouTubeLinkHandler` can extract a video ID from.
    /// Returns the first valid URL found, or `nil` if none of the strategies matched.
    public static func extractURL(from html: String) -> URL? {
        if let url = extractFromOgURL(html) { return url }
        if let url = extractFromCanonical(html) { return url }
        if let url = extractFromAnchorHref(html) { return url }
        if let url = extractFromJSONLD(html) { return url }
        if let url = extractFromEmbedIframe(html) { return url }
        return nil
    }

    // MARK: - Strategy 1: og:url meta tag

    private static func extractFromOgURL(_ html: String) -> URL? {
        // <meta property="og:url" content="https://…">  (attribute order may vary)
        let pattern = #"<meta[^>]+property\s*=\s*["']og:url["'][^>]+content\s*=\s*["']([^"']+)["']"#
            + #"|<meta[^>]+content\s*=\s*["']([^"']+)["'][^>]+property\s*=\s*["']og:url["']"#
        return firstCapture(in: html, pattern: pattern).flatMap(URL.init(string:))
    }

    // MARK: - Strategy 2: canonical link

    private static func extractFromCanonical(_ html: String) -> URL? {
        let pattern = #"<link[^>]+rel\s*=\s*["']canonical["'][^>]+href\s*=\s*["']([^"']+)["']"#
            + #"|<link[^>]+href\s*=\s*["']([^"']+)["'][^>]+rel\s*=\s*["']canonical["']"#
        return firstCapture(in: html, pattern: pattern).flatMap(URL.init(string:))
    }

    // MARK: - Strategy 3: first YouTube anchor href

    private static func extractFromAnchorHref(_ html: String) -> URL? {
        let pattern = #"<a[^>]+href\s*=\s*["'](https?://(?:www\.|m\.)?(?:youtube\.com|youtu\.be)[^"']+)["']"#
        return firstCapture(in: html, pattern: pattern).flatMap(URL.init(string:))
    }

    // MARK: - Strategy 4: JSON-LD "url" field

    private static func extractFromJSONLD(_ html: String) -> URL? {
        // Extract the content of <script type="application/ld+json"> blocks first
        let scriptPattern = #"<script[^>]+type\s*=\s*["']application/ld\+json["'][^>]*>([\s\S]*?)</script>"#
        guard let scriptContent = firstCapture(in: html, pattern: scriptPattern) else { return nil }
        // Find "url":"https://…" inside the JSON blob
        let urlPattern = #""url"\s*:\s*"(https?://[^"]+)""#
        return firstCapture(in: scriptContent, pattern: urlPattern).flatMap(URL.init(string:))
    }

    // MARK: - Strategy 5: YouTube embed iframe

    private static func extractFromEmbedIframe(_ html: String) -> URL? {
        // <iframe src="https://www.youtube.com/embed/VIDEO_ID…">
        let pattern = #"<iframe[^>]+src\s*=\s*["'](https?://(?:www\.)?youtube\.com/embed/[^"'?&]+[^"']*)["']"#
        guard let src = firstCapture(in: html, pattern: pattern) else { return nil }
        // Strip any query string from the embed URL before converting so that
        // "https://www.youtube.com/embed/ID?autoplay=1" doesn't pollute the v= value.
        // https://www.youtube.com/embed/VIDEO_ID → https://www.youtube.com/watch?v=VIDEO_ID
        let cleanSrc = src.components(separatedBy: "?").first ?? src
        let watchString = cleanSrc.replacingOccurrences(of: "/embed/", with: "/watch?v=")
        return URL(string: watchString)
    }

    // MARK: - Regex helper

    /// Returns the content of the first non-nil capture group from `pattern` in `input`.
    private static func firstCapture(in input: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(input.startIndex..., in: input)
        guard let match = regex.firstMatch(in: input, options: [], range: range) else {
            return nil
        }
        // Return the first non-nil capture group (group 0 is the full match)
        for i in 1 ..< match.numberOfRanges {
            let r = match.range(at: i)
            if r.location != NSNotFound, let swiftRange = Range(r, in: input) {
                let captured = String(input[swiftRange])
                if !captured.isEmpty { return captured }
            }
        }
        return nil
    }
}
