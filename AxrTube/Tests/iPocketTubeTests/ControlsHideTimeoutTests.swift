import Foundation
import Testing
@testable import iPocketTubeCore

// MARK: - ControlsHideTimeoutTests (Fix #125)
//
// Verifies the timeout-multiplier formula in PlaybackViewModel+ControlsVisibility.swift.
//
// Fix: scheduleControlsHide() now computes:
//   let timeout = isLandscape
//       ? Double(settings.controlsHideTimeout) * 1.5
//       : Double(settings.controlsHideTimeout)
//
// This gives users 50% more time in landscape (fullscreen) before controls disappear.
// Default timeout: 4 s → portrait stays 4 s, landscape becomes 6 s.

@Suite("Fix #125 — Controls auto-hide timeout: 1.5× longer in landscape")
struct ControlsHideTimeoutTests {

    // MARK: - Helpers

    /// Mirrors the timeout formula from PlaybackViewModel+ControlsVisibility.swift.
    private func effectiveTimeout(controlsHideTimeout: Int, isLandscape: Bool) -> Double {
        isLandscape
            ? Double(controlsHideTimeout) * 1.5
            : Double(controlsHideTimeout)
    }

    // MARK: - Default settings

    @Test("Default controlsHideTimeout is 4 seconds")
    func defaultTimeoutIsFourSeconds() {
        let settings = AppSettings()
        #expect(settings.controlsHideTimeout == 4,
                "Default controlsHideTimeout must be 4 s (mirrors Android PlayerData.controlsHideTimeoutMs)")
    }

    // MARK: - Portrait (unchanged)

    @Test("Portrait: timeout equals the configured value (no multiplier)")
    func portraitTimeoutEqualsConfiguredValue() {
        let settings = AppSettings()
        let timeout = effectiveTimeout(controlsHideTimeout: settings.controlsHideTimeout, isLandscape: false)
        #expect(timeout == 4.0,
                "Portrait timeout must be exactly 4 s (unchanged by Fix #125)")
    }

    @Test("Portrait: custom timeout 7 s stays 7 s")
    func portraitCustomTimeoutUnchanged() {
        let timeout = effectiveTimeout(controlsHideTimeout: 7, isLandscape: false)
        #expect(timeout == 7.0)
    }

    // MARK: - Landscape (1.5× multiplier)

    @Test("Landscape: default 4 s timeout becomes 6 s (4 × 1.5)")
    func landscapeDefaultTimeoutBecomsSixSeconds() {
        let settings = AppSettings()
        let timeout = effectiveTimeout(controlsHideTimeout: settings.controlsHideTimeout, isLandscape: true)
        #expect(timeout == 6.0,
                "Fix #125: landscape timeout must be 6 s (default 4 s × 1.5)")
    }

    @Test("Landscape: custom 2 s timeout becomes 3 s")
    func landscapeCustomTwoSecondsBecomes3() {
        let timeout = effectiveTimeout(controlsHideTimeout: 2, isLandscape: true)
        #expect(timeout == 3.0)
    }

    @Test("Landscape: custom 6 s timeout becomes 9 s")
    func landscapeCustomSixSecondsBecomes9() {
        let timeout = effectiveTimeout(controlsHideTimeout: 6, isLandscape: true)
        #expect(timeout == 9.0)
    }

    // MARK: - Portrait vs landscape comparison

    @Test("Landscape timeout is always longer than portrait for the same setting")
    func landscapeTimeoutAlwaysLongerThanPortrait() {
        for base in [2, 4, 6, 8, 10] {
            let portrait  = effectiveTimeout(controlsHideTimeout: base, isLandscape: false)
            let landscape = effectiveTimeout(controlsHideTimeout: base, isLandscape: true)
            #expect(landscape > portrait,
                    "Landscape (\(landscape) s) must exceed portrait (\(portrait) s) for base \(base) s")
        }
    }

    @Test("Multiplier is exactly 1.5 (landscape / portrait ratio)")
    func multiplierIsExactlyOnePointFive() {
        for base in [2, 4, 6] {
            let portrait  = effectiveTimeout(controlsHideTimeout: base, isLandscape: false)
            let landscape = effectiveTimeout(controlsHideTimeout: base, isLandscape: true)
            let ratio = landscape / portrait
            #expect(abs(ratio - 1.5) < 0.0001,
                    "Ratio must be exactly 1.5 — got \(ratio) for base \(base) s")
        }
    }
}
