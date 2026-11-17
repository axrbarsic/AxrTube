import Testing
@testable import iPocketTubeCore

@Suite("YouTube mobile navigation")
struct MobileAppTabTests {
    @Test func donorOrder() {
        #expect(MobileAppTab.visible(hideShorts: false) == [.home, .shorts, .subscriptions, .you])
    }

    @Test func hiddenShortsRemovesOnlyShorts() {
        #expect(MobileAppTab.visible(hideShorts: true) == [.home, .subscriptions, .you])
    }

    @Test func hiddenSelectionReturnsHome() {
        #expect(MobileAppTab.shorts.resolved(hideShorts: true) == .home)
        #expect(MobileAppTab.shorts.resolved(hideShorts: false) == .shorts)
    }

    @Test func otherSelectionsSurvivePreferenceChanges() {
        for tab in [MobileAppTab.home, .subscriptions, .you] {
            #expect(tab.resolved(hideShorts: true) == tab)
            #expect(tab.resolved(hideShorts: false) == tab)
        }
    }

    @Test func guestProfileKeepsLocalChannelsAndQueue() {
        #expect(MobileProfileDestination.accountEntries(signedIn: false) == [.channels])
        #expect(MobileProfileDestination.deviceEntries == [.downloads, .queue])
    }

    @Test func signedInProfileAddsOnlyYouTubeCollections() {
        // «Смотреть позже» is merged into «Сохранённое» (the .downloads row).
        #expect(MobileProfileDestination.accountEntries(signedIn: true) == [.liked, .channels])
        #expect(!MobileProfileDestination.accountEntries(signedIn: true).contains(.queue))
    }
}
