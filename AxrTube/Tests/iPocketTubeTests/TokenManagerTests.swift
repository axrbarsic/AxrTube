import Testing
import Foundation
@testable import iPocketTubeCore

// MARK: - TokenManager unit tests
//
// Tests verify the four guarantees in task #62:
//   1. Keychain roundtrip: setToken data survives a fresh instance
//   2. clearToken removes all Keychain entries
//   3. updates stream emits .refreshed on setToken
//   4. updates stream emits .signedOut on clearToken

@Suite("TokenManager")
struct TokenManagerTests {

    // MARK: - 1. Keychain roundtrip

    @Test("setToken persists all fields to Keychain across instances")
    func setTokenPersistsToKeychain() async throws {
        let service = "test-tm-\(UUID().uuidString)"
        let tm = TokenManager(keychainService: service)
        let expiry = Date(timeIntervalSinceNow: 3600)

        try await tm.setToken(
            access: "access-abc",
            refresh: "refresh-xyz",
            expiry: expiry,
            accountName: "Alice",
            avatarURL: URL(string: "https://example.com/avatar.jpg")
        )

        // New instance reads from the same Keychain service
        let tm2 = TokenManager(keychainService: service)
        #expect(tm2.initialSnapshot.accessToken == "access-abc")
        #expect(tm2.initialSnapshot.refreshToken == "refresh-xyz")
        #expect(tm2.initialSnapshot.accountName == "Alice")
        #expect(tm2.initialSnapshot.accountAvatarURL == URL(string: "https://example.com/avatar.jpg"))
        // tokenExpiry is encoded with ISO8601 — check it survived the round-trip within 1 s
        let loadedExpiry = try #require(tm2.initialSnapshot.tokenExpiry)
        #expect(abs(loadedExpiry.timeIntervalSince(expiry)) < 1)

        // Cleanup
        try await tm.clearToken()
    }

    // MARK: - 2. clearToken removes entries

    @Test("clearToken removes all Keychain entries")
    func clearTokenRemovesFromKeychain() async throws {
        let service = "test-tm-clear-\(UUID().uuidString)"
        let tm = TokenManager(keychainService: service)

        try await tm.setToken(access: "tok", refresh: "ref", expiry: nil, accountName: "Bob", avatarURL: nil)
        try await tm.clearToken()

        let tm2 = TokenManager(keychainService: service)
        #expect(tm2.initialSnapshot.accessToken == nil)
        #expect(tm2.initialSnapshot.refreshToken == nil)
        #expect(tm2.initialSnapshot.accountName == nil)
    }

    // MARK: - 3. Stream emits .refreshed on setToken

    @Test("updates stream emits .refreshed when setToken is called")
    func streamEmitsRefreshedOnSetToken() async throws {
        let tm = TokenManager(keychainService: "test-tm-stream-\(UUID().uuidString)")

        // Subscribe before triggering
        let task = Task<TokenManager.Update?, Never> {
            for await update in tm.updates { return update }
            return nil
        }

        try await tm.setToken(access: "tok-999", refresh: nil, expiry: nil, accountName: nil, avatarURL: nil)
        let update = await task.value

        if case .refreshed(let token, _) = update {
            #expect(token == "tok-999")
        } else {
            Issue.record("Expected .refreshed, got \(String(describing: update))")
        }

        // Cleanup
        try await tm.clearToken()
    }

    // MARK: - 4. Stream emits .signedOut on clearToken

    @Test("updates stream emits .signedOut when clearToken is called")
    func streamEmitsSignedOutOnClearToken() async throws {
        let tm = TokenManager(keychainService: "test-tm-so-\(UUID().uuidString)")

        // Subscribe before triggering
        let task = Task<TokenManager.Update?, Never> {
            for await update in tm.updates { return update }
            return nil
        }

        // Yield so the consuming task has a chance to start iterating
        await Task.yield()
        try await tm.clearToken()
        let update = await task.value

        if case .signedOut = update {
            // pass
        } else {
            Issue.record("Expected .signedOut, got \(String(describing: update))")
        }
    }
}
