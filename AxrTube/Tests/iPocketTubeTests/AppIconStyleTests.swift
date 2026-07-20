import Testing
@testable import iPocketTubeCore

@Suite("AxrTube app icon style")
struct AppIconStyleTests {
    @Test("Red is the default system icon and green maps to the alternate asset")
    func iconNames() {
        #expect(AppIconStyle.red.alternateIconName == nil)
        #expect(AppIconStyle.green.alternateIconName == "AppIconGreen")
    }

    @Test("System alternate icon state resolves without a second persisted owner")
    func resolvesSystemState() {
        #expect(AppIconStyle(alternateIconName: nil) == .red)
        #expect(AppIconStyle(alternateIconName: "AppIconGreen") == .green)
        #expect(AppIconStyle(alternateIconName: "UnknownFutureIcon") == .red)
    }
}
