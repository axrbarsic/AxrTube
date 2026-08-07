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

    @Test("The retired appearance modes are replaced by complete themes")
    func completeThemeSet() {
        #expect(AppSettings().themeName == .matrix)
        #expect(AppSettings.ThemeName.allCases == [
            .matrix,
            .monochrome,
            .timeline,
            .colorWashDark,
            .colorWashLight,
            .spatialDeck,
            .livingPoster,
            .signalMap,
            .prismRooms
        ])
        #expect(AppSettings.ThemeName.matrix.colorScheme == .dark)
        #expect(AppSettings.ThemeName.colorWashDark.colorScheme == .dark)
        #expect(AppSettings.ThemeName.monochrome.colorScheme == .light)
        #expect(AppSettings.ThemeName.timeline.colorScheme == .light)
        #expect(AppSettings.ThemeName.colorWashLight.colorScheme == .light)
        #expect(AppSettings.ThemeName.spatialDeck.colorScheme == .dark)
        #expect(AppSettings.ThemeName.livingPoster.colorScheme == .dark)
        #expect(AppSettings.ThemeName.signalMap.colorScheme == .light)
        #expect(AppSettings.ThemeName.prismRooms.colorScheme == .dark)
    }

    @Test("Theme capabilities drive one visual contract")
    func themeCapabilities() {
        #expect(AppSettings.ThemeName.matrix.usesMonochromeThumbnails)
        #expect(AppSettings.ThemeName.monochrome.usesMonochromeThumbnails)
        #expect(!AppSettings.ThemeName.timeline.usesMonochromeThumbnails)
        #expect(AppSettings.ThemeName.timeline.usesTimelineLayout)
        #expect(AppSettings.ThemeName.colorWashDark.usesColorWash)
        #expect(AppSettings.ThemeName.colorWashLight.usesColorWash)
        #expect(!AppSettings.ThemeName.matrix.usesColorWash)
        #expect(AppSettings.ThemeName.spatialDeck.usesSpatialDeckLayout)
        #expect(AppSettings.ThemeName.livingPoster.usesPosterLayout)
        #expect(AppSettings.ThemeName.signalMap.usesSignalMapLayout)
        #expect(AppSettings.ThemeName.prismRooms.usesPrismLayout)
    }

    @Test("Retired System Light Dark values migrate without resetting settings")
    func retiredModesMigrate() throws {
        for (legacy, expected) in [
            ("System", AppSettings.ThemeName.matrix),
            ("Dark", .matrix),
            ("Light", .colorWashLight)
        ] {
            let data = Data("\"\(legacy)\"".utf8)
            let decoded = try JSONDecoder().decode(AppSettings.ThemeName.self, from: data)
            #expect(decoded == expected)
        }
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
