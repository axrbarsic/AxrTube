import Foundation
import Testing
@testable import iPocketTubeCore

// MARK: - WatchHistoryAuthTokenTests
//
// Regression test for GitHub issue #51: watch history not updating for
// signed-in users because PlaybackViewModel+Auth.swift was not calling
// api.setAuthToken() on the PlaybackViewModel's own API instance.
//
// These tests verify the InnerTubeAPI layer behaviour that the fix depends on:
//   1. setAuthToken stores the token so subsequent network requests are
//      authenticated (WatchtimeTracker pings carry the auth token).
//   2. setAuthToken(nil) clears the stored token (sign-out path).
//   3. setAuthToken is idempotent for the same token value.
//   4. setAuthToken replaces a previously stored token (refresh path).

@Suite("Watch history auth token propagation (issue #51 regression)")
struct WatchHistoryAuthTokenTests {

    // MARK: - Helpers

    private func makeAPI() -> InnerTubeAPI {
        InnerTubeAPI()
    }

    // MARK: - Tests

    @Test("setAuthToken stores the provided token")
    func setAuthTokenStoresToken() async {
        let api = makeAPI()
        await api.setAuthToken("test-token-abc123")
        #expect(await api.authToken == "test-token-abc123")
    }

    @Test("setAuthToken(nil) clears a previously stored token")
    func setAuthTokenNilClearsToken() async {
        let api = makeAPI()
        await api.setAuthToken("initial-token")
        await api.setAuthToken(nil)
        #expect(await api.authToken == nil)
    }

    @Test("setAuthToken replaces an existing token (refresh path)")
    func setAuthTokenReplacesExistingToken() async {
        let api = makeAPI()
        await api.setAuthToken("old-token")
        await api.setAuthToken("new-token")
        #expect(await api.authToken == "new-token")
    }

    @Test("setAuthToken is idempotent for the same value")
    func setAuthTokenIdempotent() async {
        let api = makeAPI()
        await api.setAuthToken("same-token")
        await api.setAuthToken("same-token")
        #expect(await api.authToken == "same-token")
    }

    @Test("InnerTubeAPI initialised without token has nil authToken")
    func apiInitialTokenIsNil() async {
        let api = makeAPI()
        #expect(await api.authToken == nil)
    }

    @Test("InnerTubeAPI can be initialised with a token")
    func apiInitWithToken() async {
        let api = InnerTubeAPI(authToken: "init-token")
        #expect(await api.authToken == "init-token")
    }
}
