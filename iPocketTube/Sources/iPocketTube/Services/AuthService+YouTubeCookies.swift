import Foundation
import os

// MARK: - YouTube Web Session Cookie Exchange
//
// Converts our OAuth2 access token into a YouTube.com SAPISID cookie so that
// WEB_CREATOR player requests can use SAPISIDHASH Authorization (the only auth
// scheme www.youtube.com accepts for web-client nameIDs).
//
// Flow (mirrors yt-dlp's web_client auth and Chromium's identity_util.cc):
//   1. GET accounts.google.com/accounts/OAuthLogin?issueuberauth=1
//      → HTTP 302 redirect, uberauth token in Location URL
//   2. GET accounts.google.com/MergeSession?uberauth=…&continue=https://www.youtube.com/
//      → follows redirects in an isolated, non-persistent URLSession
//   3. Read SAPISID from response headers, then publish it only if the auth
//      generation is still current
//
// This must be called after a successful sign-in (step 5 of the device-code
// flow, after fetchUserInfo returns). It is a best-effort operation: failure
// is logged but does not affect sign-in state (the app degrades gracefully to
// unauthenticated WEB_CREATOR or a different client).

extension AuthService {

    /// Exchanges the current OAuth2 access token for a YouTube.com SAPISID cookie.
    /// On success, sets `self.sapisid` to the extracted value.
    /// All errors are caught internally; this method never throws.
    func fetchYouTubeWebCookies(generation: UInt64? = nil) async {
        let expectedGeneration = generation ?? authSessionGeneration
        guard isCurrentAuthGeneration(expectedGeneration), !Task.isCancelled else { return }
        // Use validAccessToken() so we refresh an expired token before making API calls.
        // This handles the case where accessToken was cleared at startup (expired) but
        // refreshToken is still valid — common after an overnight Mac restart.
        let token: String
        do {
            token = try await validAccessToken(generation: expectedGeneration)
        } catch {
            authLog.notice("[cookies] fetchYouTubeWebCookies: no valid token (\(error)) — skipping")
            return
        }

        authLog.notice("[cookies] Fetching YouTube web session cookies for SAPISIDHASH auth")

        // Diagnostic + gaiaId extraction: tokeninfo returns `sub` (numeric Gaia ID) when `openid`
        // scope is present. Required for the MultiBearer Multilogin request format.
        if let infoURL = URL(string: "https://www.googleapis.com/oauth2/v3/tokeninfo?access_token=\(token)"),
           let (infoData, _) = try? await isolatedCookieSession().data(from: infoURL) {
            // Extract gaiaId from `sub` claim (only present when openid scope is in token)
            if let infoJSON = try? JSONSerialization.jsonObject(with: infoData) as? [String: Any],
               let sub = infoJSON["sub"] as? String, !sub.isEmpty {
                guard isCurrentAuthGeneration(expectedGeneration), !Task.isCancelled else { return }
                gaiaId = sub
                authLog.notice("[cookies] account identity available — MultiBearer Multilogin enabled")
            } else {
                authLog.notice("[cookies] gaiaId not in tokeninfo — token missing openid scope; need re-sign-in")
            }
        }

        // Step 1 — get uberauth via OAuthLogin endpoint (no-redirect session)
        let oauthLoginURL = URL(string: "https://accounts.google.com/accounts/OAuthLogin?source=youtube&issueuberauth=1")!
        var req1 = URLRequest(url: oauthLoginURL)
        req1.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let config = URLSessionConfiguration.ephemeral
        let noRedirectSession = URLSession(configuration: config, delegate: NoRedirectDelegate.shared, delegateQueue: nil)

        let response1: URLResponse
        do {
            (_, response1) = try await noRedirectSession.data(for: req1)
        } catch {
            authLog.notice("[cookies] OAuthLogin request failed: \(error.localizedDescription)")
            return
        }
        guard isCurrentAuthGeneration(expectedGeneration), !Task.isCancelled else { return }

        guard let http1 = response1 as? HTTPURLResponse,
              (300..<400).contains(http1.statusCode),
              let location = http1.value(forHTTPHeaderField: "Location"),
              let mergeURL = URL(string: location) else {
            let code = (response1 as? HTTPURLResponse)?.statusCode ?? 0
            let hasAuthChallenge = (response1 as? HTTPURLResponse)?
                .value(forHTTPHeaderField: "WWW-Authenticate") != nil
            authLog.notice("[cookies] OAuthLogin did not redirect (HTTP \(code)) authChallenge=\(hasAuthChallenge) — trying Multilogin fallback")
            await fetchSAPISIDViaMultilogin(token: token, generation: expectedGeneration)
            return
        }

        authLog.notice("[cookies] OAuthLogin redirect received — loading MergeSession")

        // Step 2 — load MergeSession in an isolated session. A stale exchange must
        // never mutate the process-wide cookie jar before its generation is checked.
        let cookieCapture = IsolatedCookieCaptureDelegate()
        let mergeSession = isolatedCookieSession(delegate: cookieCapture)
        let mergeResponse: URLResponse
        do {
            (_, mergeResponse) = try await mergeSession.data(from: mergeURL)
        } catch {
            mergeSession.invalidateAndCancel()
            authLog.notice("[cookies] MergeSession request failed: \(error.localizedDescription)")
            return
        }
        cookieCapture.capture(mergeResponse)
        mergeSession.finishTasksAndInvalidate()
        guard isCurrentAuthGeneration(expectedGeneration), !Task.isCancelled else { return }

        // Step 3 — publish only the value captured by this exchange. We do not
        // copy it to HTTPCookieStorage.shared; InnerTube receives it through the
        // versioned AuthSessionSnapshot instead.
        guard let sapisidCookie = cookieCapture.cookie(named: "SAPISID") else {
            authLog.notice("[cookies] SAPISID cookie not found after MergeSession — SAPISID unavailable")
            return
        }

        authLog.notice("[cookies] ✅ SAPISID obtained — WEB_CREATOR SAPISIDHASH auth enabled")
        _ = await commitCookieCredentials(
            sapisid: sapisidCookie.value,
            generation: expectedGeneration
        )
    }

    // MARK: - Google Multilogin fallback

    /// Attempts to obtain SAPISID via the Google Multilogin endpoint.
    ///
    /// Uses the current Chromium Multilogin protocol (as of 2025):
    /// - Authorization: MultiBearer {token}:{gaiaId}  (requires `openid` scope on token)
    /// - URL param: reuseCookies=0  (replaced the old pt=I1)
    /// - Body: " " (space) to force POST — Chromium pattern
    ///
    /// Reference: chromium/src/google_apis/gaia/gaia_auth_fetcher.cc StartOAuthMultilogin()
    private func fetchSAPISIDViaMultilogin(token: String, generation: UInt64) async {
        guard isCurrentAuthGeneration(generation), !Task.isCancelled else { return }
        guard let url = URL(string: "https://accounts.google.com/oauth/multilogin?source=ChromiumBrowser&reuseCookies=0") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        // Current Chromium format: MultiBearer {token}:{gaiaId}
        // gaiaId is the numeric Gaia ID (OIDC `sub` claim) from tokeninfo when openid scope is present.
        if let gid = gaiaId, !gid.isEmpty {
            request.setValue("MultiBearer \(token):\(gid)", forHTTPHeaderField: "Authorization")
            authLog.notice("[cookies] Multilogin MultiBearer with account identity")
        } else {
            // Fallback: old Bearer format — likely to fail (INVALID_INPUT) without gaiaId.
            // User must sign out + sign in to get an openid-scoped token.
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("0", forHTTPHeaderField: "X-Goog-AuthUser")
            authLog.notice("[cookies] Multilogin fallback Bearer (no gaiaId — openid scope missing)")
        }
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = " ".data(using: .utf8)  // Space forces POST (Chromium pattern)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await isolatedCookieSession().data(for: request)
        } catch {
            authLog.notice("[cookies] Multilogin request failed: \(error.localizedDescription)")
            return
        }
        guard isCurrentAuthGeneration(generation), !Task.isCancelled else { return }

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            authLog.notice("[cookies] Multilogin HTTP \(code) — SAPISID via Multilogin unavailable")
            return
        }

        // Strip XSSI protection prefix ")]}'" before JSON parsing.
        var body = String(data: data, encoding: .utf8) ?? ""
        if body.hasPrefix(")]}'") {
            body = String(body.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let jsonData = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              (json["status"] as? String) == "OK",
              let cookies = json["cookies"] as? [[String: Any]],
              let entry = cookies.first(where: { $0["name"] as? String == "SAPISID" }),
              let value = entry["value"] as? String, !value.isEmpty else {
            authLog.notice("[cookies] Multilogin response missing SAPISID — unavailable")
            return
        }

        authLog.notice("[cookies] ✅ SAPISID obtained via Multilogin — WEB_CREATOR SAPISIDHASH auth enabled")
        _ = await commitCookieCredentials(sapisid: value, generation: generation)
    }

    @discardableResult
    func commitCookieCredentials(sapisid value: String, generation: UInt64) async -> Bool {
        guard isCurrentAuthGeneration(generation), !Task.isCancelled else { return false }
        do {
            let persisted = try await tokenManager.setSAPISID(value, generation: generation)
            guard persisted, isCurrentAuthGeneration(generation) else { return false }
            sapisid = value
            publishAuthSnapshot(phase: isSignedIn ? .signedIn : .signedOut)
            return true
        } catch {
            guard isCurrentAuthGeneration(generation) else { return false }
            authLog.error("[cookies] secure cookie persistence failed")
            self.error = error
            return false
        }
    }
}

private func isolatedCookieSession(
    delegate: URLSessionDelegate? = nil
) -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpShouldSetCookies = false
    configuration.httpCookieStorage = nil
    return URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
}

/// Captures Set-Cookie headers from every MergeSession redirect without ever
/// exposing them to the process-wide cookie store.
private final class IsolatedCookieCaptureDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var capturedCookies: [HTTPCookie] = []

    func capture(_ response: URLResponse) {
        guard let response = response as? HTTPURLResponse,
              let url = response.url else { return }
        let headerFields = response.allHeaderFields.reduce(into: [String: String]()) { result, pair in
            guard let key = pair.key as? String else { return }
            result[key] = String(describing: pair.value)
        }
        let cookies = HTTPCookie.cookies(withResponseHeaderFields: headerFields, for: url)
        lock.withLock { capturedCookies.append(contentsOf: cookies) }
    }

    func cookie(named name: String) -> HTTPCookie? {
        lock.withLock { capturedCookies.last(where: { $0.name == name }) }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        capture(response)
        completionHandler(request)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        capture(response)
        completionHandler(.allow)
    }
}

// MARK: - No-redirect URLSession delegate

/// URLSession task delegate that prevents automatic redirect following.
/// Used for the OAuthLogin step where we need the 302 Location header.
private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {

    static let shared = NoRedirectDelegate()

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        // Pass nil to prevent the redirect — the 302 response is returned as-is.
        completionHandler(nil)
    }
}
