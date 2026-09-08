import Foundation
import Testing
@testable import iPocketTubeCore

struct OscilloscopeSettingsTests {
    @Test func persistenceAndLegacyDefault() throws {
        let legacy = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        #expect(!legacy.oscilloscopeEnabled)
        var settings = AppSettings()
        settings.oscilloscopeEnabled = true
        settings.russianOnlySearchEnabled = false
        let restored = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(restored.oscilloscopeEnabled)
        #expect(!restored.russianOnlySearchEnabled)
    }
}
