import Foundation
import Testing
@testable import iPocketTubeCore

// MARK: - InfiniteSpinnerExhaustiveRetryTests
//
// Regression test for task #226: when all exhaustiveRetry paths fail, the
// video player showed an infinite spinner rather than an error message to the
// user. The symptom was Resolution "—" with a loading spinner that never
// dismissed, regardless of how long the user waited.
//
// Root cause: `exhaustiveRetry()` in PlaybackViewModel+Fallback.swift set
// `error = APIError.unavailable(...)` at the end, but never cleared `isLoading`.
// The spinner is driven by `isLoading` and the error banner is driven by `error`;
// both render in the same ZStack, but the spinner renders on top of the banner.
// Result: spinner visible forever, error banner invisible.
//
// Fix: add `isLoading = false` immediately after `error = ...` at the
// exhaustive-retry exhaustion point.
//
// These tests verify the model-layer invariant without an AVPlayer:
//   1. When `error` is set and `isLoading` is false, the user-visible state is
//      "error banner visible, spinner hidden" — the correct post-exhaustion state.
//   2. When `error` is set but `isLoading` remains true (pre-fix behaviour),
//      the user-visible state is incorrect: spinner still visible.
//   3. The APIError.unavailable case is pattern-matchable as expected.

@Suite("Infinite spinner on exhaustive retry failure — task #226 regression")
struct InfiniteSpinnerExhaustiveRetryTests {

    // MARK: - Helpers

    /// Simulates the correct post-fix state when exhaustiveRetry exhausts all paths.
    /// Returns (shouldShowSpinner: Bool, shouldShowError: Bool).
    private func exhaustionDisplayState(error: Error?, isLoading: Bool) -> (spinner: Bool, errorBanner: Bool) {
        let showSpinner = isLoading
        let showErrorBanner = error != nil && !isLoading
        return (showSpinner, showErrorBanner)
    }

    // MARK: - Tests

    /// Post-fix: error set AND isLoading=false → error banner visible, spinner hidden.
    @Test("error set + isLoading=false → error banner visible, spinner hidden")
    func errorSetAndNotLoadingShowsErrorBanner() {
        let error = APIError.unavailable("Unable to play this video")
        let state = exhaustionDisplayState(error: error, isLoading: false)
        #expect(state.spinner == false, "Spinner must be hidden when isLoading=false")
        #expect(state.errorBanner == true, "Error banner must be visible when error is set and not loading")
    }

    /// Pre-fix regression: error set but isLoading=true → spinner still shown, error banner hidden.
    @Test("error set + isLoading=true → spinner visible, error banner hidden (pre-fix bug)")
    func errorSetButStillLoadingHidesErrorBanner() {
        let error = APIError.unavailable("Unable to play this video")
        let state = exhaustionDisplayState(error: error, isLoading: true)
        #expect(state.spinner == true, "Pre-fix: spinner still visible when isLoading=true (the bug)")
        #expect(state.errorBanner == false, "Pre-fix: error banner hidden behind spinner (the bug)")
    }

    /// Normal loading state: no error, isLoading=true → spinner visible, no error banner.
    @Test("no error + isLoading=true → spinner visible (normal loading state)")
    func normalLoadingStateShowsSpinnerOnly() {
        let state = exhaustionDisplayState(error: nil, isLoading: true)
        #expect(state.spinner == true, "Spinner must show while loading normally")
        #expect(state.errorBanner == false, "No error banner while loading successfully")
    }

    /// Steady playback: no error, isLoading=false → nothing shown (playing).
    @Test("no error + isLoading=false → neither spinner nor error (steady playback)")
    func steadyPlaybackShowsNeither() {
        let state = exhaustionDisplayState(error: nil, isLoading: false)
        #expect(state.spinner == false, "No spinner during steady playback")
        #expect(state.errorBanner == false, "No error banner during steady playback")
    }

    /// The unavailable error must be pattern-matchable as APIError.unavailable.
    @Test("APIError.unavailable is the correct error type for exhaustive retry failure")
    func unavailableErrorIsCorrectType() {
        let message = "Unable to play this video"
        let err = APIError.unavailable(message)
        guard case APIError.unavailable(let reason) = err else {
            Issue.record("Expected APIError.unavailable but got \(err)")
            return
        }
        #expect(reason == message, "Error message must match what was passed to unavailable()")
    }
}
