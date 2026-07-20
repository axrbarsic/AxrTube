import Foundation
import Testing
@testable import iPocketTube
@testable import iPocketTubeCore

@Suite("Versioned auth transactions")
@MainActor
struct AuthSessionGenerationTests {
    final class MemorySecureStore: @unchecked Sendable {
        enum Failure: Error { case delete }

        private let lock = NSLock()
        private var values: [String: String] = [:]
        var failDelete = false

        func get(service: String, key: String) -> String? {
            lock.withLock { values["\(service)|\(key)"] }
        }

        func set(service: String, key: String, value: String?) {
            lock.withLock { values["\(service)|\(key)"] = value }
        }

        func delete(service: String, key: String) throws {
            try lock.withLock {
                if failDelete { throw Failure.delete }
                values.removeValue(forKey: "\(service)|\(key)")
            }
        }

        func tokenStore() -> TokenManager.SecureStore {
            TokenManager.SecureStore(
                get: { [self] in get(service: $0, key: $1) },
                set: { [self] in set(service: $0, key: $1, value: $2) },
                delete: { [self] in try delete(service: $0, key: $1) }
            )
        }
    }

    private func makeService(
        store: MemorySecureStore = MemorySecureStore(),
        serviceName: String = UUID().uuidString
    ) -> (AuthService, TokenManager, MemorySecureStore) {
        let manager = TokenManager(keychainService: serviceName, secureStore: store.tokenStore())
        return (AuthService(tokenManager: manager), manager, store)
    }

    @Test("Delayed refresh completion after sign out is ignored")
    func delayedRefreshAfterSignOut() async throws {
        let (auth, _, _) = makeService()
        let oldGeneration = auth.authSessionGeneration
        #expect(await auth.commitDeviceCredentials(
            accessToken: "old-access",
            refreshToken: "old-refresh",
            expiry: Date().addingTimeInterval(3_600),
            generation: oldGeneration
        ))

        #expect(await auth.signOut())
        #expect(!(await auth.commitRefreshedCredentials(
            accessToken: "late-access",
            expiry: Date().addingTimeInterval(3_600),
            generation: oldGeneration
        )))
        #expect(auth.authSnapshot.phase == .signedOut)
        #expect(auth.authSnapshot.accessToken == nil)
    }

    @Test("Delayed cookie exchange after sign out is ignored")
    func delayedCookieAfterSignOut() async throws {
        let (auth, _, _) = makeService()
        let oldGeneration = auth.authSessionGeneration
        #expect(await auth.commitDeviceCredentials(
            accessToken: "access",
            refreshToken: "refresh",
            expiry: Date().addingTimeInterval(3_600),
            generation: oldGeneration
        ))

        #expect(await auth.signOut())
        #expect(!(await auth.commitCookieCredentials(
            sapisid: "late-cookie",
            generation: oldGeneration
        )))
        #expect(auth.authSnapshot.sapisid == nil)
    }

    @Test("A stale cookie callback cannot replace a newer signed-in session")
    func staleCookieCannotReplaceNewSession() async throws {
        let (auth, _, _) = makeService()
        let oldGeneration = auth.authSessionGeneration
        #expect(await auth.commitDeviceCredentials(
            accessToken: "old-access",
            refreshToken: "old-refresh",
            expiry: Date().addingTimeInterval(3_600),
            generation: oldGeneration
        ))
        #expect(await auth.signOut())

        let newGeneration = auth.authSessionGeneration
        #expect(await auth.commitDeviceCredentials(
            accessToken: "new-access",
            refreshToken: "new-refresh",
            expiry: Date().addingTimeInterval(3_600),
            generation: newGeneration
        ))
        #expect(await auth.commitCookieCredentials(
            sapisid: "new-cookie",
            generation: newGeneration
        ))
        #expect(!(await auth.commitCookieCredentials(
            sapisid: "stale-cookie",
            generation: oldGeneration
        )))
        #expect(auth.authSnapshot.accessToken == "new-access")
        #expect(auth.authSnapshot.sapisid == "new-cookie")
    }

    @Test("A stale preload completion cannot repopulate account-bound cache")
    func stalePreloadCompletionIsIgnored() async {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("auth-preload-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let cache = VideoPreloadCache(disk: VideoDiskCache(cacheDir: tempDirectory))
        await cache.applyAuthSnapshot(.init(
            generation: 1,
            phase: .signedIn,
            accessToken: "access",
            sapisid: nil
        ))
        let urls = PlaybackTrackingURLs(
            playbackURL: URL(string: "https://example.invalid/playback")!,
            watchtimeURL: URL(string: "https://example.invalid/watchtime")!
        )
        #expect(await cache.store(
            trackingURLs: urls,
            nextInfo: nil,
            for: "video",
            authGeneration: 1
        ))

        await cache.applyAuthSnapshot(.signedOut(generation: 2))
        #expect(!(await cache.store(
            trackingURLs: urls,
            nextInfo: nil,
            for: "video",
            authGeneration: 1
        )))
        let cached = await cache.consume(videoId: "video")
        #expect(cached.trackingURLs == nil)
    }

    @Test("A delayed Keychain save cannot survive a newer clear")
    func delayedSecureStoreSaveCannotSurviveClear() async throws {
        let store = MemorySecureStore()
        let service = UUID().uuidString
        let manager = TokenManager(keychainService: service, secureStore: store.tokenStore())
        #expect(try await manager.setToken(
            access: "old",
            refresh: "refresh",
            expiry: nil,
            accountName: nil,
            avatarURL: nil,
            generation: 1
        ))
        try await manager.clearToken(generation: 2)

        #expect(!(try await manager.setToken(
            access: "late",
            refresh: "late-refresh",
            expiry: nil,
            accountName: nil,
            avatarURL: nil,
            generation: 1
        )))
        let relaunched = TokenManager(keychainService: service, secureStore: store.tokenStore())
        #expect(relaunched.initialSnapshot.accessToken == nil)
        #expect(relaunched.initialSnapshot.refreshToken == nil)
    }

    @Test("Reverse-order downstream callback cannot restore auth")
    func reverseOrderDownstreamIsIgnored() async {
        let api = InnerTubeAPI()
        await api.applyAuthSnapshot(.signedOut(generation: 2))
        await api.applyAuthSnapshot(.init(
            generation: 1,
            phase: .signedIn,
            accessToken: "stale",
            sapisid: "stale-cookie"
        ))

        let snapshot = await api.authSnapshotForTesting()
        #expect(snapshot.generation == 2)
        #expect(snapshot.accessToken == nil)
        #expect(snapshot.sapisid == nil)
    }

    @Test("Cold start after sign out remains signed out")
    func coldStartAfterSignOut() async {
        let store = MemorySecureStore()
        let serviceName = UUID().uuidString
        let (auth, _, _) = makeService(store: store, serviceName: serviceName)
        let generation = auth.authSessionGeneration
        #expect(await auth.commitDeviceCredentials(
            accessToken: "access",
            refreshToken: "refresh",
            expiry: Date().addingTimeInterval(3_600),
            generation: generation
        ))
        #expect(await auth.signOut())

        let relaunchedManager = TokenManager(
            keychainService: serviceName,
            secureStore: store.tokenStore()
        )
        let relaunched = AuthService(tokenManager: relaunchedManager)
        #expect(!relaunched.isSignedIn)
        #expect(relaunched.authSnapshot.phase == .signedOut)
    }

    @Test("Device sign in followed by refresh stays persisted")
    func normalSignInAndRefresh() async {
        let store = MemorySecureStore()
        let serviceName = UUID().uuidString
        let (auth, _, _) = makeService(store: store, serviceName: serviceName)
        let generation = auth.authSessionGeneration
        #expect(await auth.commitDeviceCredentials(
            accessToken: "first-access",
            refreshToken: "refresh",
            expiry: Date().addingTimeInterval(3_600),
            generation: generation
        ))
        #expect(await auth.commitRefreshedCredentials(
            accessToken: "refreshed-access",
            expiry: Date().addingTimeInterval(7_200),
            generation: generation
        ))

        let relaunched = TokenManager(
            keychainService: serviceName,
            secureStore: store.tokenStore()
        )
        #expect(relaunched.initialSnapshot.accessToken == "refreshed-access")
        #expect(relaunched.initialSnapshot.refreshToken == "refresh")
    }

    @Test("Secure-store clear failure is reported and not published as signed out")
    func secureStoreClearFailureIsTruthful() async {
        let store = MemorySecureStore()
        let (auth, _, _) = makeService(store: store)
        let generation = auth.authSessionGeneration
        #expect(await auth.commitDeviceCredentials(
            accessToken: "access",
            refreshToken: "refresh",
            expiry: Date().addingTimeInterval(3_600),
            generation: generation
        ))
        store.failDelete = true

        #expect(!(await auth.signOut()))
        #expect(auth.authSnapshot.phase == .secureStoreClearFailed)
        #expect(auth.isSignedIn)
        #expect(auth.error != nil)
    }
}
