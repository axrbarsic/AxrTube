import Foundation
import Testing
@testable import iPocketTubeCore

// MARK: - TVSeekButtonTests

@Suite("Apple TV Seek Button Behaviour")
struct TVSeekButtonTests {

    /// Verifies that the default AppSettings seek durations are positive and
    /// within a sensible range. The tvOS D-pad handler now seeks directly by
    /// settings.seekBackSeconds / settings.seekForwardSeconds when controls are
    /// visible but no specific button is highlighted — so these values must be valid.
    @Test func defaultSeekDurationsArePositiveAndReasonable() {
        let settings = AppSettings()
        #expect(settings.seekBackSeconds > 0)
        #expect(settings.seekForwardSeconds > 0)
        #expect(settings.seekBackSeconds <= 60)
        #expect(settings.seekForwardSeconds <= 60)
    }

    /// Back and forward seek durations should be non-zero distinct values
    /// (back is negative direction, forward positive) so D-pad left/right
    /// produce the expected directional seeks.
    @Test func seekBackIsNegativeDirectionSeekForwardIsPositive() {
        let settings = AppSettings()
        let backDelta = -Double(settings.seekBackSeconds)
        let forwardDelta = Double(settings.seekForwardSeconds)
        #expect(backDelta < 0)
        #expect(forwardDelta > 0)
    }

    // MARK: - task-100: availableSeekOptions & preferredAudioLanguage defaults

    /// Default seekBackSeconds must be in the availableSeekOptions list so the
    /// tvOS Picker pre-selects a valid entry without migration.
    @Test func seekBackSecondsIsValidPickerOption() {
        let settings = AppSettings()
        #expect(AppSettings.availableSeekOptions.contains(settings.seekBackSeconds))
    }

    /// Default seekForwardSeconds must be in the availableSeekOptions list.
    @Test func seekForwardSecondsIsValidPickerOption() {
        let settings = AppSettings()
        #expect(AppSettings.availableSeekOptions.contains(settings.seekForwardSeconds))
    }

    /// preferredAudioLanguage default must be nil — the tvOS Picker
    /// represents this as "System Default".
    @Test func preferredAudioLanguageDefaultIsNil() {
        let settings = AppSettings()
        #expect(settings.preferredAudioLanguage == nil)
    }
}
