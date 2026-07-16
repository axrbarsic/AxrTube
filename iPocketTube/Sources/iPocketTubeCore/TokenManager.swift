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

    enum SecureStoreError: LocalizedError, Sendable {
        case keychain(operation: String, status: OSStatus)

        var errorDescription: String? {
            switch self {
            case .keychain(let operation, let status):
                return "Secure storage \(operation) failed (status \(status))"
            }
        }
    }

    struct SecureStore: Sendable {
        let get: @Sendable (_ service: String, _ key: String) -> String?
        let set: @Sendable (_ service: String, _ key: String, _ value: String?) throws -> Void
        let delete: @Sendable (_ service: String, _ key: String) throws -> Void

        static let system = SecureStore(
            get: TokenManager.kcGet,
            set: TokenManager.kcSet,
            delete: TokenManager.kcDelete
        )
    }

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
    private var generation: UInt64 = 0

    private let service: String
    private let secureStore: SecureStore

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
        self.init(keychainService: keychainService, secureStore: .system)
    }

    init(keychainService: String, secureStore: SecureStore) {
        service = keychainService
        self.secureStore = secureStore

        var cont: AsyncStream<Update>.Continuation!
        let stream = AsyncStream<Update> { cont = $0 }
        updates = stream
        continuation = cont

        let snap = Snapshot(
            accessToken:     secureStore.get(keychainService, "st_access_token"),
            refreshToken:    secureStore.get(keychainService, "st_refresh_token"),
            tokenExpiry: {
                guard let s = secureStore.get(keychainService, "st_token_expiry")
                else { return nil }
                return ISO8601DateFormatter().date(from: s)
            }(),
            accountName:     secureStore.get(keychainService, "st_account_name"),
            accountAvatarURL: secureStore.get(keychainService, "st_avatar_url")
                                .flatMap(URL.init(string:)),
            sapisid:         secureStore.get(keychainService, "st_sapisid")
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

    /// Advances the persistence generation without changing stored values.
    /// Used by in-memory test sign-out so late saves from an older generation
    /// are still rejected.
    public func invalidate(generation requestedGeneration: UInt64) {
        if requestedGeneration > generation {
            generation = requestedGeneration
        }
    }

    // MARK: - Mutations

    @discardableResult
    public func setToken(
        access: String?,
        refresh: String?,
        expiry: Date?,
        accountName: String?,
        avatarURL: URL?,
        generation requestedGeneration: UInt64 = 0
    ) throws -> Bool {
        guard requestedGeneration >= generation else { return false }
        generation = requestedGeneration
        self.accessToken      = access
        self.refreshToken     = refresh
        self.tokenExpiry      = expiry
        self.accountName      = accountName
        self.accountAvatarURL = avatarURL
        try persistToKeychain()
        continuation?.yield(.refreshed(token: access, expiresAt: expiry))
        return true
    }

    /// Persists the SAPISID cookie to Keychain so it survives app restarts and
    /// is available on the next launch without requiring a fresh cookie exchange.
    @discardableResult
    public func setSAPISID(_ value: String?, generation requestedGeneration: UInt64 = 0) throws -> Bool {
        guard requestedGeneration >= generation else { return false }
        generation = requestedGeneration
        sapisid = value
        try secureStore.set(service, "st_sapisid", value)
        return true
    }

    public func clearToken(generation requestedGeneration: UInt64? = nil) throws {
        let targetGeneration = requestedGeneration ?? (generation &+ 1)
        guard targetGeneration >= generation else { return }
        generation = targetGeneration
        try deleteFromKeychain()
        accessToken      = nil
        refreshToken     = nil
        tokenExpiry      = nil
        accountName      = nil
        accountAvatarURL = nil
        sapisid          = nil
        continuation?.yield(.signedOut)
    }

    // MARK: - Private Keychain I/O

    private func persistToKeychain() throws {
        let fmt = ISO8601DateFormatter()
        try secureStore.set(service, "st_access_token", accessToken)
        try secureStore.set(service, "st_refresh_token", refreshToken)
        try secureStore.set(service, "st_token_expiry", tokenExpiry.map { fmt.string(from: $0) })
        try secureStore.set(service, "st_account_name", accountName)
        try secureStore.set(service, "st_avatar_url", accountAvatarURL?.absoluteString)
    }

    private func deleteFromKeychain() throws {
        for key in ["st_access_token", "st_refresh_token", "st_token_expiry",
                    "st_account_name", "st_avatar_url", "st_sapisid"] {
            try secureStore.delete(service, key)
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

    private static func kcSet(service: String, key: String, value: String?) throws {
        let deleteQuery: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key,
        ]
        let deleteStatus = SecItemDelete(deleteQuery as CFDictionary)
        guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else {
            throw SecureStoreError.keychain(operation: "delete-before-save", status: deleteStatus)
        }
        guard let value, let data = value.data(using: .utf8) else { return }
        let addQuery: [CFString: Any] = [
            kSecClass:          kSecClassGenericPassword,
            kSecAttrService:    service,
            kSecAttrAccount:    key,
            kSecValueData:      data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw SecureStoreError.keychain(operation: "save", status: addStatus)
        }
    }

    private static func kcDelete(service: String, key: String) throws {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecureStoreError.keychain(operation: "delete", status: status)
        }
    }
}
