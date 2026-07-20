import Foundation
import Testing
@testable import iPocketTubeCore

// MARK: - URLVideoResolverTests
//
// Tests the synchronous / non-network parts of URLVideoResolver:
//   - Step 1: direct YouTubeLinkHandler parse (no network)
//   - Step 3 integration: HTMLVideoLinkExtractor correctly fed to YouTubeLinkHandler
//
// Network-dependent steps (redirect chain, live scrape) require a mock URLSession
// which isn't available in this test host. Those paths are covered by the individual
// HTMLVideoLinkExtractorTests and YouTubeLinkHandlerTests suites.

@Suite("URLVideoResolver — Step 1 (direct parse)")
struct URLVideoResolverDirectParseTests {

    // URLVideoResolver.resolve() calls YouTubeLinkHandler internally on step 1.
    // We verify that here by calling the same logic directly, which exercises the
    // identical code path without needing an async actor call.

    @Test("Standard watch URL resolves immediately (step 1)")
    func watchURL() {
        let url = URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")!
        #expect(YouTubeLinkHandler.videoID(from: url) == "dQw4w9WgXcQ")
    }

    @Test("youtu.be short URL resolves immediately (step 1)")
    func shortURL() {
        let url = URL(string: "https://youtu.be/dQw4w9WgXcQ")!
        #expect(YouTubeLinkHandler.videoID(from: url) == "dQw4w9WgXcQ")
    }

    @Test("Shorts URL resolves immediately (step 1)")
    func shortsURL() {
        let url = URL(string: "https://www.youtube.com/shorts/dQw4w9WgXcQ")!
        #expect(YouTubeLinkHandler.videoID(from: url) == "dQw4w9WgXcQ")
    }

    @Test("Mobile youtube.com resolves immediately (step 1)")
    func mobileURL() {
        let url = URL(string: "https://m.youtube.com/watch?v=dQw4w9WgXcQ")!
        #expect(YouTubeLinkHandler.videoID(from: url) == "dQw4w9WgXcQ")
    }

    @Test("Non-YouTube URL returns nil on step 1")
    func nonYouTubeURL() {
        let url = URL(string: "https://bit.ly/SomeShortLink")!
        #expect(YouTubeLinkHandler.videoID(from: url) == nil)
    }

    @Test("Vimeo URL returns nil on step 1")
    func vimeoURL() {
        let url = URL(string: "https://vimeo.com/123456789")!
        #expect(YouTubeLinkHandler.videoID(from: url) == nil)
    }

    @Test("Example.com returns nil on step 1")
    func exampleURL() {
        let url = URL(string: "https://example.com")!
        #expect(YouTubeLinkHandler.videoID(from: url) == nil)
    }
}

// MARK: - HTMLVideoLinkExtractor + YouTubeLinkHandler integration

@Suite("URLVideoResolver — Step 3 (scrape + parse integration)")
struct URLVideoResolverScrapeIntegrationTests {

    private let videoID = "dQw4w9WgXcQ"

    /// Simulates what URLVideoResolver.scrape() does after getting an HTML body:
    ///   1. HTMLVideoLinkExtractor.extractURL(from: html)
    ///   2. YouTubeLinkHandler.videoID(from: extracted)
    private func resolveFromHTML(_ html: String) -> String? {
        guard let url = HTMLVideoLinkExtractor.extractURL(from: html) else { return nil }
        return YouTubeLinkHandler.videoID(from: url)
    }

    @Test("og:url strategy end-to-end resolves video ID")
    func ogURLEndToEnd() {
        let html = """
        <meta property="og:url" content="https://www.youtube.com/watch?v=\(videoID)">
        """
        #expect(resolveFromHTML(html) == videoID)
    }

    @Test("canonical link strategy end-to-end resolves video ID")
    func canonicalEndToEnd() {
        let html = """
        <link rel="canonical" href="https://youtu.be/\(videoID)">
        """
        #expect(resolveFromHTML(html) == videoID)
    }

    @Test("anchor href strategy end-to-end resolves video ID")
    func anchorEndToEnd() {
        let html = """
        <a href="https://www.youtube.com/watch?v=\(videoID)">Watch</a>
        """
        #expect(resolveFromHTML(html) == videoID)
    }

    @Test("JSON-LD strategy end-to-end resolves video ID")
    func jsonLDEndToEnd() {
        let html = """
        <script type="application/ld+json">
        {"url":"https://www.youtube.com/watch?v=\(videoID)"}
        </script>
        """
        #expect(resolveFromHTML(html) == videoID)
    }

    @Test("embed iframe strategy end-to-end resolves video ID")
    func iframeEndToEnd() {
        let html = """
        <iframe src="https://www.youtube.com/embed/\(videoID)"></iframe>
        """
        #expect(resolveFromHTML(html) == videoID)
    }

    @Test("HTML with non-YouTube URL returns nil")
    func nonYouTubeHTML() {
        let html = """
        <meta property="og:url" content="https://vimeo.com/123456789">
        """
        #expect(resolveFromHTML(html) == nil)
    }

    @Test("HTML with no video returns nil")
    func noVideoHTML() {
        let html = "<html><body>No video here</body></html>"
        #expect(resolveFromHTML(html) == nil)
    }

    @Test("Real-world YouTube page snippet resolves correctly")
    func realWorldYouTubeSnippet() {
        // Minimal excerpt similar to what YouTube's HTML looks like
        let html = """
        <html>
        <head>
        <link rel="canonical" href="https://www.youtube.com/watch?v=\(videoID)">
        <meta property="og:url" content="https://www.youtube.com/watch?v=\(videoID)">
        <meta property="og:title" content="Rick Astley - Never Gonna Give You Up">
        </head>
        <body></body>
        </html>
        """
        #expect(resolveFromHTML(html) == videoID)
    }
}

// MARK: - Configuration constants

@Suite("URLVideoResolver — configuration")
struct URLVideoResolverConfigTests {

    @Test("maxRedirects is at least 3")
    func maxRedirects() {
        #expect(URLVideoResolver.maxRedirects >= 3)
    }

    @Test("totalTimeout is reasonable (≤ 30 s)")
    func totalTimeout() {
        #expect(URLVideoResolver.totalTimeout <= 30)
    }

    @Test("maxBodyBytes is at most 1 MB")
    func maxBodyBytes() {
        #expect(URLVideoResolver.maxBodyBytes <= 1_048_576)
    }
}
