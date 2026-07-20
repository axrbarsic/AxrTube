#if !os(tvOS)
import Foundation
import Testing
@testable import iPocketTube
@testable import iPocketTubeCore

// MARK: - TOSWatchHistoryAuthTokenTests
//
// Regression tests for GitHub issues #51/#78: watch history not recorded for
// signed-in users playing through the TOS player. PlaybackViewModel+Auth.swift
// already propagates the auth token to its own InnerTubeAPI instance (fixed for
// #51 in the AVPlayer pipeline), but TOSPlayerViewModel — which is now the iOS
// default for regular videos (since 4.6) — had no equivalent at all, so every
// WatchtimeTracker ping it sent went out unauthenticated. These tests verify
// TOSPlayerViewModel+Auth.swift's updateAuthToken/updateSAPISID propagate to the
// view model's own `api` instance, mirroring WatchHistoryAuthTokenTests.swift's
// coverage of the AVPlayer-side fix.

@Suite("TOS watch history auth token propagation (issues #51/#78 regression)")
@MainActor
struct TOSWatchHistoryAuthTokenTests {

    private func makeVM() -> TOSPlayerViewModel {
        TOSPlayerViewModel(videoId: "test-auth-video", api: InnerTubeAPI())
    }

    @Test("updateAuthToken propagates the token to the view model's own API instance")
    func updateAuthTokenPropagates() async throws {
        let vm = makeVM()
        vm.updateAuthToken("test-token-abc123")

        var observed: String?
        for _ in 0..<50 {
            observed = await vm.api.authToken
            if observed == "test-token-abc123" { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(observed == "test-token-abc123")
    }

    @Test("updateAuthToken(nil) clears a previously propagated token")
    func updateAuthTokenNilClears() async throws {
        let vm = makeVM()
        vm.updateAuthToken("initial-token")
        for _ in 0..<50 {
            if await vm.api.authToken == "initial-token" { break }
            try? await Task.sleep(for: .milliseconds(10))
        }

        vm.updateAuthToken(nil)
        var observed: String? = "unchanged"
        for _ in 0..<50 {
            observed = await vm.api.authToken
            if observed == nil { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(observed == nil)
    }

    @Test("updateSAPISID propagates the cookie to the view model's own API instance")
    func updateSAPISIDPropagates() async throws {
        let vm = makeVM()
        vm.updateSAPISID("test-sapisid-xyz")

        var observed: String?
        for _ in 0..<50 {
            observed = await vm.api.sapisid
            if observed == "test-sapisid-xyz" { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(observed == "test-sapisid-xyz")
    }
}
#endif
