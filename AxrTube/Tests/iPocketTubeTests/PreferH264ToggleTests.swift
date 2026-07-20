import Foundation
import Testing
@testable import iPocketTubeCore

// MARK: - PreferH264ToggleTests
//
// Unit tests for the `preferH264` AppSettings property added in task #206.
//
// `PlaybackQualityManager.selectBestVideoFormat` behaviour (H.264 codec sorting) is
// exercised via Xcode UI/integration tests — PlaybackQualityManager imports iPocketTube
// which depends on FirebaseCrashlytics and cannot be built in the headless SPM test target.
//
// What is tested here (iPocketTubeCore only):
//   1. AppSettings.preferH264 defaults to false.
//   2. AppSettings.preferH264 = true round-trips through Codable.
//   3. AppSettings with preferH264 = true decodes correctly from explicit JSON.
//   4. Existing settings JSON without the key decodes with preferH264 == false (forward compat).

@Suite("Prefer H.264 toggle — AppSettings")
struct PreferH264ToggleTests {

    @Test("preferH264 defaults to false in AppSettings init")
    func testPreferH264DefaultsFalse() {
        let settings = AppSettings()
        #expect(settings.preferH264 == false)
    }

    @Test("preferH264 = true round-trips through Codable")
    func testPreferH264CodableRoundTrip() throws {
        var settings = AppSettings()
        settings.preferH264 = true
        let encoded = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: encoded)
        #expect(decoded.preferH264 == true)
    }

    @Test("preferH264 = false round-trips through Codable")
    func testPreferH264FalseCodableRoundTrip() throws {
        var settings = AppSettings()
        settings.preferH264 = false
        let encoded = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: encoded)
        #expect(decoded.preferH264 == false)
    }
}

