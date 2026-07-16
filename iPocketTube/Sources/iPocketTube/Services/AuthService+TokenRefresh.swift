import Foundation
import iPocketTubeCore

extension AuthService {

    // MARK: - Token refresh

    func refreshAccessToken(
        refreshToken: String,
        creds: YouTubeClientCredentials,
        generation: UInt64? = nil
    ) async throws {
        let expectedGeneration = generation ?? authSessionGeneration
        guard isCurrentAuthGeneration(expectedGeneration) else { throw CancellationError() }
        var req = URLRequest(url: Self.tokenURL)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = formEncode([
            "refresh_token": refreshToken,
            "client_id":     creds.clientId,
            "client_secret": creds.clientSecret,
            "grant_type":    "refresh_token",
        ])

        let (data, response) = try await URLSession.shared.data(for: req)
        guard isCurrentAuthGeneration(expectedGeneration), !Task.isCancelled else {
            throw CancellationError()
        }
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0

        // Detect permanent refresh-token failures (revoked, expired, invalid credentials).
        // Google returns HTTP 400/401 with {"error":"invalid_grant"} or "invalid_client".
        // These are unrecoverable — sign out so the user isn't stuck with stale tokens.
        if (statusCode == 400 || statusCode == 401),
           let errJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let oauthError = errJson["error"] as? String,
            ["invalid_grant", "invalid_client", "unauthorized_client"].contains(oauthError) {
            authLog.error("refreshAccessToken: permanent failure (\(oauthError)) — signing out")
            _ = await signOut()
            throw AuthError.tokenExchangeFailed
        }

        guard (200..<300).contains(statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw AuthError.tokenExchangeFailed }

        let expiry = (json["expires_in"] as? TimeInterval)
            .map { Date().addingTimeInterval($0 - 60) }
        guard await commitRefreshedCredentials(
            accessToken: json["access_token"] as? String,
            expiry: expiry,
            generation: expectedGeneration
        ) else {
            throw CancellationError()
        }
    }

    @discardableResult
    func commitRefreshedCredentials(
        accessToken newAccessToken: String?,
        expiry: Date?,
        generation: UInt64
    ) async -> Bool {
        guard isCurrentAuthGeneration(generation), !Task.isCancelled else { return false }
        accessToken = newAccessToken
        if let expiry { tokenExpiry = expiry }
        isSignedIn = accessToken != nil || refreshToken != nil
        guard await saveToKeychain(generation: generation) else { return false }
        guard isCurrentAuthGeneration(generation) else { return false }
        publishAuthSnapshot(phase: isSignedIn ? .signedIn : .signedOut)
        scheduleProactiveRefresh()
        return true
    }
}
