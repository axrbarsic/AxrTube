import Foundation
import Observation
import os
import iPocketTubeCore

let authLog = CrashlyticsLogger(category: "Auth")

// MARK: - AuthService
//
// Google OAuth 2.0 **Device Authorization Grant** flow (RFC 8628).
//
// Mirrors exactly how the Android iPocketTube app authenticates:
//  1. Fetch client_id / client_secret by scraping YouTube's own base.js
//     (see YouTubeClientCredentialsFetcher in iPocketTubeCore).
//  2. POST to https://oauth2.googleapis.com/device/code → get user_code +
//     verification_url (youtube.com/activate).
//  3. Show the user_code on-screen so the user can enter it at
//     https://youtube.com/activate on any device.
//  4. Poll https://oauth2.googleapis.com/token every `interval` seconds until
//     the user approves or cancels.
//
// No redirect URI, no registered client ID, no ASWebAuthenticationSession.

@MainActor
@Observable
public final class AuthService {

    // MARK: - Observable state

    public internal(set) var isSignedIn: Bool = false
    public internal(set) var accountName: String?
    public internal(set) var accountAvatarURL: URL?
    public var error: Error?

    /// Non-nil while waiting for the user to enter the code at youtube.com/activate.
    /// `internal(set)` so extension files (e.g. AuthService+DeviceFlow) can clear it.
    public internal(set) var pendingActivation: ActivationInfo?

    // MARK: - ActivationInfo

    public struct ActivationInfo: Sendable {
        /// The short code the user types at youtube.com/activate (e.g. "ABCD-1234").
        public let userCode: String
        /// Typically https://yt.be/activate (as used by the Android iPocketTube client).
        public let verificationURL: URL
        /// When this activation attempt expires.
        public let expiresAt: Date
    }

    // MARK: - Internal state
    // Properties below are `internal` (no keyword) so extension files in this
    // module can read and write them without going through private accessors.

    public internal(set) var accessToken: String?
    /// YouTube.com SAPISID cookie value obtained via the OAuthLogin/MergeSession flow.
    /// Used by InnerTubeAPI.postWebCreator to compute the SAPISIDHASH Authorization header.
    /// Set asynchronously after TV device sign-in completes; nil when signed out or not yet fetched.
    public internal(set) var sapisid: String?
    /// Numeric Google Account ID (GAIA "sub" claim) extracted from the OpenID Connect id_token
    /// or from tokeninfo when `openid` scope is present. Required by the Chromium-style Multilogin
    /// endpoint (Authorization: MultiBearer {token}:{gaiaId}).
    public internal(set) var gaiaId: String?
    var refreshToken: String?
    var tokenExpiry: Date?
    var pollTask: Task<Void, Never>?

    var credentialsFetcher = YouTubeClientCredentialsFetcher()
    // `openid` scope: required so that the token exchange response includes an id_token whose
    // `sub` claim is the numeric Gaia ID. Google's current Multilogin endpoint uses
    // `Authorization: MultiBearer {token}:{gaiaId}` and requires the numeric Gaia ID.
    // `youtube` scope: accepted by Google's Multilogin endpoint.
    // `gdata` + `youtube-paid-content`: backwards compatibility with existing TV API calls.
    // `accounts.reauth` scope was tested (Decision 15/16) and confirmed NOT grantable by the
    // YouTube TV device-code client — Google returns non-2xx on the /device/code request and
    // sign-in fails entirely. Removed. The Multilogin path remains blocked.
    var scope = "openid http://gdata.youtube.com https://www.googleapis.com/auth/youtube-paid-content https://www.googleapis.com/auth/youtube"
    private var tokenRefreshTask: Task<Void, Never>?

    // State persisted across foreground/background transitions so that the
    // poll loop can be restarted without re-requesting a device code.
    private var currentDeviceCode: String?
    private var currentInterval: TimeInterval = 5
    private var currentCreds: YouTubeClientCredentials?
    private var isSigningIn: Bool = false

    public let tokenManager: TokenManager

    // MARK: - Static endpoint URLs (known-valid literals)

    static let deviceCodeURL   = URL(string: "https://oauth2.googleapis.com/device/code")!
    static let tokenURL        = URL(string: "https://oauth2.googleapis.com/token")!
    static let accountsListURL = URL(string: "https://www.youtube.com/youtubei/v1/account/accounts_list")!

    public init() {
        tokenManager = TokenManager()
        loadFromKeychain()
        // UI-testing override: treat the session as signed-in so the home feed
        // renders its full shelves (including the injected Shorts row) without
        // requiring real keychain credentials.
        if ProcessInfo.processInfo.arguments.contains("--uitesting-signed-in") {
            isSignedIn = true
        }
        // If already signed in but no account info (e.g. stored before the
        // fetchUserInfo fix), refresh it silently in the background.
        if isSignedIn && accountName == nil {
            Task {
                do { try await fetchUserInfo() }
                catch { authLog.error("fetchUserInfo on init failed: \(String(describing: error))") }
            }
        }
    }

    // MARK: - Public API

    /// Step 1 – request a device code and expose the user_code for display.
    /// Call this when the user taps "Sign in".
    public func beginSignIn() async {
        guard !isSigningIn else {
            authLog.notice("beginSignIn() — already in progress, ignoring duplicate call")
            return
        }
        isSigningIn = true
        defer { isSigningIn = false }
        pollTask?.cancel()
        error = nil
        pendingActivation = nil
        authLog.notice("beginSignIn() — fetching credentials…")

        let creds = await credentialsFetcher.credentials()
        authLog.notice("Using clientId: \(creds.clientId)")

        do {
            let deviceResponse = try await retryWithBackoff { [self] in
                try await requestDeviceCode(creds: creds)
            }
            authLog.notice("✅ Got device code. userCode=\(deviceResponse.userCode) expiresIn=\(deviceResponse.expiresIn)s interval=\(deviceResponse.interval)s")
            let expiresAt = Date().addingTimeInterval(TimeInterval(deviceResponse.expiresIn))
            let fallbackURL = URL(string: "https://yt.be/activate") ?? URL(string: "https://youtube.com/activate")!
            let verURL = URL(string: deviceResponse.verificationURL) ?? fallbackURL

            pendingActivation = ActivationInfo(
                userCode: deviceResponse.userCode,
                verificationURL: verURL,
                expiresAt: expiresAt
            )

            // Step 2 – start polling in the background
            let interval = max(TimeInterval(deviceResponse.interval), 5)
            currentDeviceCode = deviceResponse.deviceCode
            currentInterval   = interval
            currentCreds      = creds
            pollTask = Task { [weak self] in
                await self?.pollForToken(deviceCode: deviceResponse.deviceCode,
                                         interval: interval,
                                         creds: creds)
            }
        } catch {
            authLog.error("❌ beginSignIn error: \(String(describing: error))")
            self.error = error
        }
    }

    /// Cancel an in-progress activation.
    public func cancelSignIn() {
        pollTask?.cancel()
        pollTask = nil
        pendingActivation = nil
        currentDeviceCode = nil
        currentCreds      = nil
    }

    /// Call when the app returns to the foreground while a sign-in is in progress.
    public func handleForeground() {
        guard !isSignedIn, accessToken == nil else { return }
        guard let pending = pendingActivation, pending.expiresAt > Date() else { return }
        guard let deviceCode = currentDeviceCode, let creds = currentCreds else { return }
        authLog.notice("handleForeground() — restarting poll immediately")
        pollTask?.cancel()
        let interval = currentInterval
        pollTask = Task { [weak self] in
            await self?.pollForToken(deviceCode: deviceCode,
                                     interval: interval,
                                     creds: creds,
                                     pollImmediately: true)
        }
    }

    /// Refreshes the access token now if it has expired or will expire within the next 5 minutes.
    /// Safe to call on every app-active transition. No-op when not signed in.
    public func refreshIfNeeded() async {
        guard isSignedIn, let expiry = tokenExpiry else { return }
        guard expiry.timeIntervalSinceNow < 5 * 60 else { return }
        guard let refresh = refreshToken else { return }
        authLog.notice("refreshIfNeeded() — token expires soon, refreshing")
        let creds = await credentialsFetcher.credentials()
        do {
            try await refreshAccessToken(refreshToken: refresh, creds: creds)
        } catch {
            authLog.error("refreshIfNeeded() failed: \(String(describing: error))")
        }
    }

    public func signOut() {
        pollTask?.cancel()
        pollTask = nil
        tokenRefreshTask?.cancel()
        tokenRefreshTask = nil
        accessToken      = nil
        sapisid          = nil
        refreshToken     = nil
        tokenExpiry      = nil
        accountName      = nil
        accountAvatarURL = nil
        isSignedIn       = false
        pendingActivation = nil
        clearKeychain()
    }

    /// Clears the in-memory auth session without touching the keychain.
    /// Used by `--uitesting-sign-out` so UI tests can verify signed-out UI on a
    /// simulator that has real credentials stored in the keychain.
    public func clearSession() {
        pollTask?.cancel()
        pollTask = nil
        tokenRefreshTask?.cancel()
        tokenRefreshTask = nil
        accessToken      = nil
        sapisid          = nil
        refreshToken     = nil
        tokenExpiry      = nil
        accountName      = nil
        accountAvatarURL = nil
        isSignedIn       = false
        pendingActivation = nil
    }

    /// Returns a valid access token, refreshing if necessary.
    public func validAccessToken() async throws -> String {
        if let t = accessToken, let exp = tokenExpiry, exp > Date() { return t }
        guard let refresh = refreshToken else { throw AuthError.notSignedIn }
        let creds = await credentialsFetcher.credentials()
        try await retryWithBackoff(maxAttempts: 2) { [self] in
            try await refreshAccessToken(refreshToken: refresh, creds: creds)
        }
        guard let t = accessToken else { throw AuthError.notSignedIn }
        return t
    }

    // MARK: - Proactive token refresh

    /// Schedules a background Task that sleeps until 5 minutes before expiry, then refreshes.
    func scheduleProactiveRefresh() {
        tokenRefreshTask?.cancel()
        guard let expiry = tokenExpiry, refreshToken != nil else { return }
        let delay = max(expiry.timeIntervalSinceNow - 5 * 60, 0)
        authLog.notice("scheduleProactiveRefresh() — refreshing in \(Int(delay))s")
        tokenRefreshTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            guard self.isSignedIn, let refresh = self.refreshToken else { return }
            let creds = await self.credentialsFetcher.credentials()
            do {
                try await self.refreshAccessToken(refreshToken: refresh, creds: creds)
                authLog.notice("scheduleProactiveRefresh() — token refreshed ✅")
                self.scheduleProactiveRefresh()
            } catch {
                authLog.error("scheduleProactiveRefresh() failed: \(String(describing: error))")
            }
        }
    }
}
