import Foundation
import Testing
@testable import iPocketTubeCore

// MARK: - SettingsQualityPersistenceTests
//
// Regression tests for #151: SettingsStore previously forced preferredQuality
// back to .auto on every app launch, discarding any user-selected quality.
// These tests verify the codec round-trip preserves the chosen quality value.

@Suite("Settings Quality Persistence")
struct SettingsQualityPersistenceTests {

    // MARK: - Codec round-trip

    @Test("preferredQuality survives JSON encode/decode round-trip for each case",
          arguments: AppSettings.VideoQuality.allCases)
    func qualityRoundTrips(_ quality: AppSettings.VideoQuality) throws {
        var settings = AppSettings()
        settings.preferredQuality = quality
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        #expect(decoded.preferredQuality == quality,
                "#151 regression: preferredQuality must survive encode/decode — expected \(quality), got \(decoded.preferredQuality)")
    }

    @Test("Default preferredQuality is .auto")
    func defaultQualityIsAuto() {
        let settings = AppSettings()
        #expect(settings.preferredQuality == .auto)
    }

    @Test("VideoQuality rawValues are human-readable for UI display")
    func qualityRawValues() {
        #expect(AppSettings.VideoQuality.auto.rawValue == "auto")
        #expect(AppSettings.VideoQuality.q1080.rawValue == "1080p")
        #expect(AppSettings.VideoQuality.q720.rawValue == "720p")
    }

    @Test("VideoQuality.maxHeight returns nil only for .auto")
    func autoHasNilMaxHeight() {
        #expect(AppSettings.VideoQuality.auto.maxHeight == nil)
        for quality in AppSettings.VideoQuality.allCases where quality != .auto {
            #expect(quality.maxHeight != nil, "\(quality) must have a non-nil maxHeight")
        }
    }
}
