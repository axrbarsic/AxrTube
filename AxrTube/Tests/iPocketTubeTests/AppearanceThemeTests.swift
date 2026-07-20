import Foundation
import Testing
@testable import iPocketTubeCore
@testable import iPocketTube

@Suite("Appearance theme contract")
struct AppearanceThemeTests {
    @Test("Every appearance choice survives settings persistence",
          arguments: AppSettings.ThemeName.allCases)
    func appearanceRoundTrips(_ appearance: AppSettings.ThemeName) throws {
        var settings = AppSettings()
        settings.themeName = appearance

        let encoded = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: encoded)

        #expect(decoded.themeName == appearance)
    }

    @Test("System is the default and does not force a color scheme")
    func systemDefault() {
        #expect(AppSettings().themeName == .system)
        #expect(AppSettings.ThemeName.system.colorScheme == nil)
        #expect(AppSettings.ThemeName.dark.colorScheme == .dark)
        #expect(AppSettings.ThemeName.light.colorScheme == .light)
    }

    @Test("Both palettes meet text and selected-control contrast")
    func semanticContrast() {
        for palette in [iPocketTubeThemePalette.light, .dark] {
            #expect(palette.primaryText.contrastRatio(with: palette.background) >= 7.0)
            #expect(palette.secondaryText.contrastRatio(with: palette.background) >= 4.5)
            #expect(palette.accentForeground.contrastRatio(with: palette.accent) >= 4.5)
        }
    }

    @Test("Light and dark palettes are independent semantic surfaces")
    func palettesAreDistinct() {
        #expect(iPocketTubeThemePalette.light.background != iPocketTubeThemePalette.dark.background)
        #expect(iPocketTubeThemePalette.light.panel != iPocketTubeThemePalette.dark.panel)
        #expect(iPocketTubeThemePalette.light.accent != iPocketTubeThemePalette.dark.accent)
    }
}
