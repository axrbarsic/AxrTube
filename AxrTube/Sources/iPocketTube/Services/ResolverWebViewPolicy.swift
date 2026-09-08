#if canImport(WebKit)
import WebKit

@MainActor
enum ResolverWebViewPolicy {
    static func configure(_ configuration: WKWebViewConfiguration) {
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        #if os(iOS)
        configuration.allowsInlineMediaPlayback = true
        configuration.allowsPictureInPictureMediaPlayback = false
        #endif
    }

    static func isolate(_ webView: WKWebView) {
        // Native suspension survives page scripts calling play() or unmute().
        // Metadata, cookies and network requests remain available to extraction.
        webView.setAllMediaPlaybackSuspended(true, completionHandler: {})
    }
}
#endif
