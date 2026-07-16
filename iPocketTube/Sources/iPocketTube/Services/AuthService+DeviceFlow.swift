import Foundation
import iPocketTubeCore

extension AuthService {

    // MARK: - Device Code request

    struct DeviceCodeResponse {
        let deviceCode: String
        let userCode: String
        let verificationURL: String
        let expiresIn: Int
        let interval: Int
    }

    func requestDeviceCode(creds: YouTubeClientCredentials) async throws -> DeviceCodeResponse {
        var req = URLRequest(url: Self.deviceCodeURL)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = formEncode([
            "client_id":     creds.clientId,
            "client_secret": creds.clientSecret,
            "scope":         scope,
        ])

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw AuthError.deviceCodeRequestFailed
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let deviceCode = json["device_code"]       as? String,
              let userCode   = json["user_code"]         as? String,
              let verURL     = json["verification_url"]  as? String,
              let expiresIn  = json["expires_in"]        as? Int
        else { throw AuthError.deviceCodeRequestFailed }

        return DeviceCodeResponse(
            deviceCode:      deviceCode,
            userCode:        userCode,
            verificationURL: verURL,
            expiresIn:       expiresIn,
            interval:        json["interval"] as? Int ?? 5
        )
    }

    // MARK: - Polling

    func pollForToken(
        deviceCode: String,
        interval: TimeInterval,
        creds: YouTubeClientCredentials,
        pollImmediately: Bool = false
    ) async {
        authLog.notice("Starting poll loop (interval \(Int(interval))s, immediate=\(pollImmediately))")
        var skipInitialSleep = pollImmediately
        while !Task.isCancelled {
            if skipInitialSleep {
                skipInitialSleep = false
            } else {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
            guard !Task.isCancelled else { return }

            do {
                try await exchangeDeviceCode(deviceCode: deviceCode, creds: creds)
                authLog.notice("✅ Token exchanged — fetching user info")
                try await fetchUserInfo()
                authLog.notice("✅ Signed in as \(self.accountName ?? "unknown")")
                // Fetch YouTube.com SAPISID cookie for WEB_CREATOR SAPISIDHASH auth.
                // Best-effort: runs in background, failure doesn't block sign-in.
                Task { await self.fetchYouTubeWebCookies() }
                pendingActivation = nil
                pollTask = nil
                return
            } catch AuthError.authorizationPending {
                authLog.debug("Polling… (authorization_pending)")
                continue
            } catch AuthError.slowDown {
                authLog.notice("slow_down received — waiting extra 5s")
                try? await Task.sleep(nanoseconds: UInt64(5 * 1_000_000_000))
                continue
            } catch let urlError as URLError {
                authLog.notice("Network error during poll (transient, retrying): \(urlError.localizedDescription)")
                continue
            } catch {
                authLog.error("❌ Poll error: \(String(describing: error))")
                if isSignedIn { return }
                self.error = error
                pendingActivation = nil
                pollTask = nil
                return
            }
        }
        authLog.notice("Poll loop cancelled")
    }

    func exchangeDeviceCode(deviceCode: String, creds: YouTubeClientCredentials) async throws {
        var req = URLRequest(url: Self.tokenURL)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = formEncode([
            "code":          deviceCode,
            "client_id":     creds.clientId,
            "client_secret": creds.clientSecret,
            "grant_type":    "http://oauth.net/grant_type/device/1.0",
        ])

        let (data, response) = try await URLSession.shared.data(for: req)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AuthError.tokenExchangeFailed
        }

        // RFC 8628 §3.5 error codes
        if let oauthError = json["error"] as? String {
            switch oauthError {
            case "authorization_pending": throw AuthError.authorizationPending
            case "slow_down":             throw AuthError.slowDown
            case "access_denied":         throw AuthError.cancelled
            case "expired_token":         throw AuthError.deviceCodeExpired
            default:                      throw AuthError.tokenExchangeFailed
            }
        }

        guard (200..<300).contains(statusCode) else { throw AuthError.tokenExchangeFailed }

        accessToken = json["access_token"] as? String
        if let r = json["refresh_token"] as? String { refreshToken = r }
        if let exp = json["expires_in"] as? TimeInterval {
            tokenExpiry = Date().addingTimeInterval(exp - 60)
        }
        isSignedIn = accessToken != nil
        saveToKeychain()
        scheduleProactiveRefresh()
    }
}
