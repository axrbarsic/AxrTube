import Foundation

// MARK: - TokenManager
//
// Actor that owns all Keychain storage for OAuth tokens.
//
// AuthService creates and holds a TokenManager, reading initial token state
// via `initialSnapshot` (nonisolated — safe from synchronous init).
// Consumers that want to react to future token changes subscribe to `updates`.
//
// Conservative scope (task #62): AuthService delegates Keychain I/O here but
// still maintains its own @Observable stored vars for UI binding. The
// AsyncStream is available for future consumer migration but not yet consumed
// by InnerTubeAPI / VideoPreloadCache.

public actor TokenManager {

    // MARK: - Types

    public enum Update: Sendable {
        case refreshed(token: String?, expiresAt: Date?)
        case signedOut
    }

    public struct Snapshot: Sendable {
        public let accessToken: String?
        public let refreshToken: String?
        public let tokenExpiry: Date?
        public let accountName: String?
        public let accountAvatarURL: URL?
        /// YouTube.com SAPISID cookie for WEB_CREATOR SAPISIDHASH auth.
        public let sapisid: String?
    }

    // MARK: - State

    private var accessToken: String?
    private var refreshToken: String?
    private var tokenExpiry: Date?
    private var accountName: String?
    private var accountAvatarURL: URL?
    private var sapisid: String?

    private let service: String

    // MARK: - Stream

    private var continuation: AsyncStream<Update>.Continuation?

    /// Subscribe to receive future token updates without polling AuthService.
    /// `nonisolated let` — accessible without `await`, safe cross-actor.
    public nonisolated let updates: AsyncStream<Update>

    // MARK: - Initial snapshot

    /// Snapshot of Keychain values at init time.
    /// `nonisolated let` — AuthService.init() reads this without `await`.
    public nonisolated let initialSnapshot: Snapshot

    // MARK: - Init

    // Legacy Keychain service must remain stable or an install-over would lose the signed-in session.
    public init(keychainService: String = "com.smarttube.auth") {
        service = keychainService

        var cont: AsyncStream<Update>.Continuation!
        let stream = AsyncStream<Update> { cont = $0 }
        updates = stream
        continuation = cont

        let snap = Snapshot(
            accessToken:     Self.kcGet(service: keychainService, key: "st_access_token"),
            refreshToken:    Self.kcGet(service: keychainService, key: "st_refresh_token"),
            tokenExpiry: {
                guard let s = Self.kcGet(service: keychainService, key: "st_token_expiry")
                else { return nil }
                return ISO8601DateFormatter().date(from: s)
            }(),
            accountName:     Self.kcGet(service: keychainService, key: "st_account_name"),
            accountAvatarURL: Self.kcGet(service: keychainService, key: "st_avatar_url")
                                .flatMap(URL.init(string:)),
            sapisid:         Self.kcGet(service: keychainService, key: "st_sapisid")
        )
        initialSnapshot  = snap
        accessToken      = snap.accessToken
        refreshToken     = snap.refreshToken
        tokenExpiry      = snap.tokenExpiry
        accountName      = snap.accountName
        accountAvatarURL = snap.accountAvatarURL
        sapisid          = snap.sapisid
    }

    // MARK: - Reads

    public func currentAccessToken() -> String?  { accessToken }
    public func currentRefreshToken() -> String? { refreshToken }
    public func currentTokenExpiry() -> Date?    { tokenExpiry }
    public func currentAccountName() -> String?  { accountName }
    public func currentAvatarURL() -> URL?       { accountAvatarURL }
    public func isSignedIn() -> Bool             { accessToken != nil }

    // MARK: - Mutations

    public func setToken(
        access: String?,
        refresh: String?,
        expiry: Date?,
        accountName: String?,
        avatarURL: URL?
    ) {
        self.accessToken      = access
        self.refreshToken     = refresh
        self.tokenExpiry      = expiry
        self.accountName      = accountName
        self.accountAvatarURL = avatarURL
        persistToKeychain()
        continuation?.yield(.refreshed(token: access, expiresAt: expiry))
    }

    /// Persists the SAPISID cookie to Keychain so it survives app restarts and
    /// is available on the next launch without requiring a fresh cookie exchange.
    public func setSAPISID(_ value: String?) {
        sapisid = value
        Self.kcSet(service: service, key: "st_sapisid", value: value)
    }

    public func clearToken() {
        accessToken      = nil
        refreshToken     = nil
        tokenExpiry      = nil
        accountName      = nil
        accountAvatarURL = nil
        sapisid          = nil
        deleteFromKeychain()
        continuation?.yield(.signedOut)
    }

    // MARK: - Private Keychain I/O

    private func persistToKeychain() {
        let fmt = ISO8601DateFormatter()
        Self.kcSet(service: service, key: "st_access_token",  value: accessToken)
        Self.kcSet(service: service, key: "st_refresh_token", value: refreshToken)
        Self.kcSet(service: service, key: "st_token_expiry",  value: tokenExpiry.map { fmt.string(from: $0) })
        Self.kcSet(service: service, key: "st_account_name",  value: accountName)
        Self.kcSet(service: service, key: "st_avatar_url",    value: accountAvatarURL?.absoluteString)
    }

    private func deleteFromKeychain() {
        for key in ["st_access_token", "st_refresh_token", "st_token_expiry",
                    "st_account_name", "st_avatar_url", "st_sapisid"] {
            Self.kcDelete(service: service, key: key)
        }
    }

    // MARK: - Static (nonisolated) Keychain helpers
    // Static methods are nonisolated — safe to call from actor init.

    private static func kcGet(service: String, key: String) -> String? {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key,
            kSecReturnData:  true,
            kSecMatchLimit:  kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func kcSet(service: String, key: String, value: String?) {
        let deleteQuery: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key,
        ]
        SecItemDelete(deleteQuery as CFDictionary)
        guard let value, let data = value.data(using: .utf8) else { return }
        let addQuery: [CFString: Any] = [
            kSecClass:          kSecClassGenericPassword,
            kSecAttrService:    service,
            kSecAttrAccount:    key,
            kSecValueData:      data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock,
        ]
        SecItemAdd(addQuery as CFDictionary, nil)
    }

    private static func kcDelete(service: String, key: String) {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
