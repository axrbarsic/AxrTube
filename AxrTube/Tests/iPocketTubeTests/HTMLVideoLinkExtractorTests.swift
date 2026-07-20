import Foundation
import Testing
@testable import iPocketTubeCore

// MARK: - HTMLVideoLinkExtractorTests
//
// Tests each of the five URL-extraction strategies in isolation.
// All tests are pure-synchronous — no network required.

@Suite("HTMLVideoLinkExtractor")
struct HTMLVideoLinkExtractorTests {

    private let videoID = "dQw4w9WgXcQ"
    private var watchURL: String { "https://www.youtube.com/watch?v=\(videoID)" }
    private var shortURL: String { "https://youtu.be/\(videoID)" }

    // MARK: - Strategy 1: og:url

    @Test("og:url content attribute extracts YouTube URL")
    func ogURLContentFirst() {
        let html = """
        <meta property="og:url" content="\(watchURL)">
        """
        let url = HTMLVideoLinkExtractor.extractURL(from: html)
        #expect(url?.absoluteString == watchURL)
    }

    @Test("og:url with reversed attribute order still extracted")
    func ogURLContentReversed() {
        let html = """
        <meta content="\(watchURL)" property="og:url">
        """
        let url = HTMLVideoLinkExtractor.extractURL(from: html)
        #expect(url?.absoluteString == watchURL)
    }

    @Test("og:url with single quotes is extracted")
    func ogURLSingleQuotes() {
        let html = "<meta property='og:url' content='\(watchURL)'>"
        let url = HTMLVideoLinkExtractor.extractURL(from: html)
        #expect(url?.absoluteString == watchURL)
    }

    // MARK: - Strategy 2: canonical link

    @Test("canonical link href extracts YouTube URL")
    func canonicalHref() {
        let html = """
        <link rel="canonical" href="\(watchURL)">
        """
        let url = HTMLVideoLinkExtractor.extractURL(from: html)
        #expect(url?.absoluteString == watchURL)
    }

    @Test("canonical with reversed attribute order is extracted")
    func canonicalHrefReversed() {
        let html = """
        <link href="\(watchURL)" rel="canonical">
        """
        let url = HTMLVideoLinkExtractor.extractURL(from: html)
        #expect(url?.absoluteString == watchURL)
    }

    // MARK: - Strategy 3: anchor href

    @Test("youtu.be anchor href extracts URL")
    func anchorYoutuBe() {
        let html = """
        <a href="\(shortURL)">Watch video</a>
        """
        let url = HTMLVideoLinkExtractor.extractURL(from: html)
        #expect(url?.absoluteString == shortURL)
    }

    @Test("youtube.com anchor href extracts URL")
    func anchorYoutubeCom() {
        let html = """
        <a href="\(watchURL)">Watch</a>
        """
        let url = HTMLVideoLinkExtractor.extractURL(from: html)
        #expect(url?.absoluteString == watchURL)
    }

    @Test("non-YouTube anchor href is ignored")
    func anchorNonYouTube() {
        let html = """
        <a href="https://vimeo.com/123456789">Vimeo video</a>
        """
        let url = HTMLVideoLinkExtractor.extractURL(from: html)
        #expect(url == nil)
    }

    // MARK: - Strategy 4: JSON-LD

    @Test("JSON-LD url field extracts YouTube URL")
    func jsonLD() {
        let html = """
        <script type="application/ld+json">
        {"@context":"https://schema.org","@type":"VideoObject","url":"\(watchURL)","name":"Test"}
        </script>
        """
        let url = HTMLVideoLinkExtractor.extractURL(from: html)
        #expect(url?.absoluteString == watchURL)
    }

    @Test("JSON-LD with non-YouTube url is ignored")
    func jsonLDNonYouTube() {
        let html = """
        <script type="application/ld+json">
        {"url":"https://example.com/video"}
        </script>
        """
        // extractURL returns a URL but YouTubeLinkHandler won't find a videoID
        // — this is tested at the resolver level, not here
        let url = HTMLVideoLinkExtractor.extractURL(from: html)
        // url may be non-nil but should be https://example.com/video — not a YouTube URL
        if let url {
            #expect(YouTubeLinkHandler.videoID(from: url) == nil)
        }
    }

    // MARK: - Strategy 5: embed iframe

    @Test("YouTube embed iframe src is converted to watch URL")
    func embedIframe() {
        let html = """
        <iframe src="https://www.youtube.com/embed/\(videoID)" allowfullscreen></iframe>
        """
        let url = HTMLVideoLinkExtractor.extractURL(from: html)
        let id = url.flatMap { YouTubeLinkHandler.videoID(from: $0) }
        #expect(id == videoID)
    }

    @Test("embed iframe with extra query params still extracts video ID")
    func embedIframeWithParams() {
        let html = """
        <iframe src="https://www.youtube.com/embed/\(videoID)?autoplay=1&start=30"></iframe>
        """
        let url = HTMLVideoLinkExtractor.extractURL(from: html)
        let id = url.flatMap { YouTubeLinkHandler.videoID(from: $0) }
        #expect(id == videoID)
    }

    // MARK: - Empty / no-match

    @Test("HTML with no YouTube references returns nil")
    func noMatch() {
        let html = "<html><body><p>Hello world</p></body></html>"
        let url = HTMLVideoLinkExtractor.extractURL(from: html)
        #expect(url == nil)
    }

    @Test("empty string returns nil")
    func emptyHTML() {
        let url = HTMLVideoLinkExtractor.extractURL(from: "")
        #expect(url == nil)
    }

    // MARK: - Priority: og:url wins over anchor

    @Test("og:url is preferred over anchor href when both present")
    func ogURLPriorityOverAnchor() {
        let otherID = "AAAAAAAAAAA"
        let html = """
        <meta property="og:url" content="\(watchURL)">
        <a href="https://youtu.be/\(otherID)">other</a>
        """
        let url = HTMLVideoLinkExtractor.extractURL(from: html)
        // Should return the og:url, not the anchor
        #expect(url?.absoluteString == watchURL)
    }
}
