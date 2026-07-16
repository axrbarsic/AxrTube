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
//      → follows redirects, sets SAPISID cookie in HTTPCookieStorage.shared
//   3. Read SAPISID value, store on AuthService.sapisid
//
// This must be called after a successful sign-in (step 5 of the device-code
// flow, after fetchUserInfo returns). It is a best-effort operation: failure
// is logged but does not affect sign-in state (the app degrades gracefully to
// unauthenticated WEB_CREATOR or a different client).

extension AuthService {

    /// Exchanges the current OAuth2 access token for a YouTube.com SAPISID cookie.
    /// On success, sets `self.sapisid` to the extracted value.
    /// All errors are caught internally; this method never throws.
    func fetchYouTubeWebCookies() async {
        // Use validAccessToken() so we refresh an expired token before making API calls.
        // This handles the case where accessToken was cleared at startup (expired) but
        // refreshToken is still valid — common after an overnight Mac restart.
        let token: String
        do {
            token = try await validAccessToken()
        } catch {
            authLog.notice("[cookies] fetchYouTubeWebCookies: no valid token (\(error)) — skipping")
            return
        }

        authLog.notice("[cookies] Fetching YouTube web session cookies for SAPISIDHASH auth")

        // Diagnostic + gaiaId extraction: tokeninfo returns `sub` (numeric Gaia ID) when `openid`
        // scope is present. Required for the MultiBearer Multilogin request format.
        if let infoURL = URL(string: "https://www.googleapis.com/oauth2/v3/tokeninfo?access_token=\(token)"),
           let (infoData, _) = try? await URLSession.shared.data(from: infoURL) {
            let infoStr = String(data: infoData, encoding: .utf8) ?? "<non-UTF8>"
            authLog.notice("[cookies] tokeninfo=\(infoStr)")
            // Extract gaiaId from `sub` claim (only present when openid scope is in token)
            if let infoJSON = try? JSONSerialization.jsonObject(with: infoData) as? [String: Any],
               let sub = infoJSON["sub"] as? String, !sub.isEmpty {
                gaiaId = sub
                authLog.notice("[cookies] gaiaId=\(sub) — MultiBearer Multilogin enabled")
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

        guard let http1 = response1 as? HTTPURLResponse,
              (300..<400).contains(http1.statusCode),
              let location = http1.value(forHTTPHeaderField: "Location"),
              let mergeURL = URL(string: location) else {
            let code = (response1 as? HTTPURLResponse)?.statusCode ?? 0
            let wwwAuth = (response1 as? HTTPURLResponse)?.value(forHTTPHeaderField: "WWW-Authenticate") ?? "none"
            authLog.notice("[cookies] OAuthLogin did not redirect (HTTP \(code)) WWW-Authenticate=\(wwwAuth) — trying Multilogin fallback")
            await fetchSAPISIDViaMultilogin(token: token)
            return
        }

        authLog.notice("[cookies] OAuthLogin redirect received — loading MergeSession")

        // Step 2 — load MergeSession URL via shared session (sets SAPISID cookie)
        // URLSession.shared uses HTTPCookieStorage.shared and follows redirects by default.
        do {
            let (_, _) = try await URLSession.shared.data(from: mergeURL)
        } catch {
            authLog.notice("[cookies] MergeSession request failed: \(error.localizedDescription)")
            return
        }

        // Step 3 — read SAPISID from shared cookie storage
        let ytURL = URL(string: "https://www.youtube.com")!
        let cookies = HTTPCookieStorage.shared.cookies(for: ytURL) ?? []
        guard let sapisidCookie = cookies.first(where: { $0.name == "SAPISID" }) else {
            authLog.notice("[cookies] SAPISID cookie not found after MergeSession — SAPISID unavailable")
            return
        }

        authLog.notice("[cookies] ✅ SAPISID obtained — WEB_CREATOR SAPISIDHASH auth enabled")
        sapisid = sapisidCookie.value
        // Persist to Keychain so it survives app restarts — no re-fetch needed on next launch.
        Task { await tokenManager.setSAPISID(sapisidCookie.value) }
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
    private func fetchSAPISIDViaMultilogin(token: String) async {
        guard let url = URL(string: "https://accounts.google.com/oauth/multilogin?source=ChromiumBrowser&reuseCookies=0") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        // Current Chromium format: MultiBearer {token}:{gaiaId}
        // gaiaId is the numeric Gaia ID (OIDC `sub` claim) from tokeninfo when openid scope is present.
        if let gid = gaiaId, !gid.isEmpty {
            request.setValue("MultiBearer \(token):\(gid)", forHTTPHeaderField: "Authorization")
            authLog.notice("[cookies] Multilogin MultiBearer with gaiaId=\(gid)")
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
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            authLog.notice("[cookies] Multilogin request failed: \(error.localizedDescription)")
            return
        }

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let body = String(data: data, encoding: .utf8) ?? "<non-UTF8>"
            authLog.notice("[cookies] Multilogin HTTP \(code) body=\(body) — SAPISID via Multilogin unavailable")
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
        sapisid = value
        Task { await tokenManager.setSAPISID(value) }
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
