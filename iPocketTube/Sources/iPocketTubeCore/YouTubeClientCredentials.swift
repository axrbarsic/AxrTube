import Foundation
import os
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private let credLog = Logger(subsystem: appSubsystem, category: "Credentials")

// MARK: - YouTubeClientCredentials
//
// Mirrors Android's AppServiceInt / ClientData approach:
// fetches the YouTube TV base.js file and extracts the OAuth client_id and
// client_secret with the same regex patterns used in MediaServiceCore.
//
// The credentials belong to the "Android TV / TVHTML5" OAuth app that Google
// ships inside its own YouTube player JS — they are not a user-registered
// application's credentials.  iPocketTube Android has been using this technique
// since the project began.

public struct YouTubeClientCredentials: Sendable {
    public let clientId: String
    public let clientSecret: String
}

public actor YouTubeClientCredentialsFetcher {

    // Known-good fallback that matches what Android scrapes most of the time.
    // Used when the JS scrape fails so the app still works without a network
    // round-trip on first launch.
    private static let fallback = YouTubeClientCredentials(
        clientId:     "861556708454-d6dlm3lh05idd8npek18k6be8ba3oc68.apps.googleusercontent.com",
        clientSecret: "SboVhoG9s0rNafixCSGGKXAT"
    )

    private var cached: YouTubeClientCredentials?
    private let session: URLSession

    public init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        self.session = URLSession(configuration: config)
    }

    /// Returns credentials, using the cache when available.
    public func credentials() async -> YouTubeClientCredentials {
        if let c = cached {
            credLog.notice("Using cached credentials: \(c.clientId, privacy: .public)")
            return c
        }
        credLog.notice("Fetching credentials from YouTube TV JS…")
        if let c = await fetchFromYouTube() {
            credLog.notice("✅ Scraped → clientId: \(c.clientId, privacy: .public)")
            cached = c
            return c
        }
        credLog.notice("⚠️ Scrape failed — using fallback credentials")
        return Self.fallback
    }

    // MARK: - Private

    private func fetchFromYouTube() async -> YouTubeClientCredentials? {
        // Step 1: fetch the YouTube TV homepage to find the base.js URL
        guard let baseJSURL = await fetchBaseJSURL() else { return nil }

        // Step 2: fetch base.js and extract client credentials with regex
        guard let js = await fetchText(from: baseJSURL) else { return nil }

        return extractCredentials(from: js)
    }

    private func fetchBaseJSURL() async -> URL? {
        // YouTube TV landing page (same source Android uses via TVHTML5 client)
        guard let url = URL(string: "https://www.youtube.com/tv") else { return nil }
        var request = URLRequest(url: url)
        request.setValue(
            "Mozilla/5.0 (SMART-TV; Linux; Tizen 5.0) AppleWebKit/537.36 (KHTML, like Gecko) SamsungBrowser/2.1 Chrome/56.0.2924.0 TV Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )
        guard let html = await fetchText(request: request) else {
            credLog.error("❌ Failed to fetch youtube.com/tv HTML")
            return nil
        }
        credLog.notice("Fetched youtube.com/tv (\(html.count, privacy: .public) chars), searching for base-js…")

        // Android AppInfo.java pattern: id="base-js" src="(path)"
        // The src is a /m=base kabuki URL, NOT a /base.js file path.
        let pattern = #"id="base-js" src="([^"]+)""#
        guard let match = html.range(of: pattern, options: .regularExpression),
              let srcRange = html[match].range(of: #"src="([^"]+)""#, options: .regularExpression)
        else {
            credLog.error("❌ base-js src URL not found in HTML")
            return nil
        }
        // Extract just the URL value from src="..."
        let srcFragment = String(html[match][srcRange])
        let urlValue = srcFragment
            .replacingOccurrences(of: "src=\"", with: "")
            .replacingOccurrences(of: "\"", with: "")
        guard let baseURL = URL(string: "https://www.youtube.com" + urlValue) else {
            credLog.error("❌ Could not construct base-js URL from: \(urlValue, privacy: .public)")
            return nil
        }
        credLog.notice("Found base-js URL: \(baseURL, privacy: .public)")
        return baseURL
    }

    private func extractCredentials(from js: String) -> YouTubeClientCredentials? {
        // Mirrors Android ClientData.java regex patterns:
        //   clientId:"([-\w]+\.apps\.googleusercontent\.com)",\n?[$\w]+:"\w+"
        //   clientId:"[-\w]+\.apps\.googleusercontent\.com",\n?[$\w]+:"(\w+)"
        let clientIdPattern  = #"clientId:"([-\w]+\.apps\.googleusercontent\.com)""#
        let clientSecPattern = #"clientId:"[-\w]+\.apps\.googleusercontent\.com",\n?[$\w]+:"(\w+)""#

        guard let clientId = firstCapture(in: js, pattern: clientIdPattern) else {
            credLog.error("❌ clientId pattern not matched in base.js (\(js.count, privacy: .public) chars)")
            return nil
        }
        guard let secret = firstCapture(in: js, pattern: clientSecPattern) else {
            credLog.error("❌ clientSecret pattern not matched (clientId was \(clientId, privacy: .public))")
            return nil
        }

        return YouTubeClientCredentials(clientId: clientId, clientSecret: secret)
    }

    // MARK: - Helpers

    private func fetchText(from url: URL) async -> String? {
        await fetchText(request: URLRequest(url: url))
    }

    private func fetchText(request: URLRequest) async -> String? {
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode)
        else {
            let url = request.url?.absoluteString ?? "?"
            credLog.error("❌ HTTP request failed: \(url, privacy: .public)")
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private func firstCapture(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[range])
    }
}
