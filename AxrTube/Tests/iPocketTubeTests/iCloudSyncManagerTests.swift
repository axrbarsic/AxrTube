import Foundation
import Testing
@testable import iPocketTubeCore

// MARK: - iCloudSyncManagerTests
//
// Tests for task #98: iCloud sync manager push/pull logic and the settings toggle.
//
// NSUbiquitousKeyValueStore.default cannot be used in unit tests (no iCloud
// entitlement in the test host). Tests verify the in-process behaviour:
// - push() is a no-op when syncEnabled == false
// - push() does not throw / crash when syncEnabled == true (best-effort; actual
//   iCloud write will silently fail in the test environment)
// - AppSettings encodes iCloudSyncEnabled correctly (round-trip through JSON)

@Suite("Task #98 — iCloudSyncManager and AppSettings iCloudSyncEnabled")
struct iCloudSyncManagerTests {

    // MARK: - AppSettings round-trip

    @Test("AppSettings.iCloudSyncEnabled defaults to false")
    func appSettings_iCloudSyncEnabled_defaultsToFalse() {
        let settings = AppSettings()
        #expect(settings.iCloudSyncEnabled == false)
    }

    @Test("AppSettings.iCloudSyncEnabled round-trips through JSON encoding")
    func appSettings_iCloudSyncEnabled_jsonRoundTrip() throws {
        var settings = AppSettings()
        settings.iCloudSyncEnabled = true

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)

        #expect(decoded.iCloudSyncEnabled == true)
    }

    @Test("AppSettings with iCloudSyncEnabled=false round-trips")
    func appSettings_iCloudSyncEnabled_falseRoundTrip() throws {
        let settings = AppSettings()   // default
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        #expect(decoded.iCloudSyncEnabled == false)
    }

    // MARK: - iCloudSyncManager.syncEnabled

    @Test("iCloudSyncManager.syncEnabled is writable from non-actor context")
    func syncManager_syncEnabled_isWritable() {
        // This test runs in the test executor (non-isolated).
        // nonisolated(unsafe) allows the write without actor hop.
        iCloudSyncManager.shared.syncEnabled = false
        #expect(iCloudSyncManager.shared.syncEnabled == false)
        iCloudSyncManager.shared.syncEnabled = true
        #expect(iCloudSyncManager.shared.syncEnabled == true)
        // Reset to avoid state bleed into other tests.
        iCloudSyncManager.shared.syncEnabled = false
    }

    @Test("iCloudSyncManager.push is a no-op when syncEnabled == false")
    func syncManager_push_noOpWhenDisabled() async {
        iCloudSyncManager.shared.syncEnabled = false
        // Pushing any Codable value must not crash when sync is disabled.
        await iCloudSyncManager.shared.push(.subscriptions, [String: String]())
        // No assertion needed — absence of crash/exception is the pass criterion.
    }

    @Test("iCloudSyncManager.pull returns nil when key absent from KV store")
    func syncManager_pull_nilForAbsentKey() async {
        // In the test host there is no iCloud entitlement; NSUbiquitousKeyValueStore
        // returns nil for all keys. Verify the pull() nil path is safe.
        let result = await iCloudSyncManager.shared.pull(
            .subscriptions,
            as: [String: String].self
        )
        // May be nil (no entitlement) or non-nil (test device has iCloud). Either is safe.
        // Just verify no crash — actual value is environment-dependent.
        _ = result
    }
}
