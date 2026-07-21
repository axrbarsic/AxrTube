import Testing
@testable import iPocketTubeCore

@Suite("AxrTube app icon style")
struct AppIconStyleTests {
    @Test("Every signed alternate icon has a unique system name")
    func iconNamesAreUnique() {
        #expect(AppIconStyle.red.alternateIconName == nil)

        let alternateNames = AppIconStyle.allCases.compactMap(\.alternateIconName)
        #expect(alternateNames.count == AppIconStyle.allCases.count - 1)
        #expect(Set(alternateNames).count == alternateNames.count)
    }

    @Test("System alternate icon state round-trips through the single policy owner")
    func resolvesSystemState() {
        for style in AppIconStyle.allCases {
            #expect(AppIconStyle(alternateIconName: style.alternateIconName) == style)
        }

        #expect(AppIconStyle(alternateIconName: "UnknownFutureIcon") == .red)
    }

    @Test("Background and glyph galleries expose all requested colors")
    func galleryGroups() {
        let background = AppIconStyle.styles(for: .background)
        let glyph = AppIconStyle.styles(for: .glyph)

        #expect(background.count == 9)
        #expect(glyph.count == 9)
        #expect(background.map(\.colorName) == glyph.map(\.colorName))
        #expect(Set(background + glyph) == Set(AppIconStyle.allCases))
    }
}
