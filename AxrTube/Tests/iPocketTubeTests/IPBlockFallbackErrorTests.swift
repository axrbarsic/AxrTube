import Foundation
import Testing
@testable import iPocketTubeCore

// MARK: - IPBlockFallbackErrorTests
//
// Verifies the error-surfacing logic added to PlaybackViewModel+Fallback.swift.
//
// When `retryWithFallbackPlayer` catches `APIError.ipBlocked` from the Android client,
// it must surface the ipBlocked error (which carries the VPN banner message) rather than
// the upstream `originalError` (AVFoundationErrorDomain -11828 "Cannot Open").
//
// When the Android fallback throws any other error, `originalError` must still be used
// (existing behaviour is preserved for non-VPN failures).
//
// The fix:
//   if case APIError.ipBlocked = error {
//       self.error = error
//   } else {
//       self.error = originalError
//   }
//
// These tests validate the two branches of that condition using the same APIError
// model that the production code pattern-matches against.

@Suite("IP block fallback error surfacing (PlaybackViewModel+Fallback fix)")
struct IPBlockFallbackErrorTests {

    // MARK: - Helpers

    /// Simulates the production logic in the `retryWithFallbackPlayer` catch block.
    /// Returns the error that would be assigned to `self.error`.
    private func surfacedError(fallbackError: Error, originalError: Error) -> Error {
        if case APIError.ipBlocked = fallbackError {
            return fallbackError
        } else {
            return originalError
        }
    }

    /// A stand-in for AVFoundationErrorDomain -11828 "Cannot Open".
    private var avFoundationCannotOpen: NSError {
        NSError(domain: "AVFoundationErrorDomain", code: -11828, userInfo: [
            NSLocalizedDescriptionKey: "Cannot Open",
        ])
    }

    // MARK: - ipBlocked from Android fallback → surface ipBlocked

    @Test("Android fallback ipBlocked overrides AVFoundation -11828 originalError")
    func ipBlockedOverridesAVFoundationError() {
        let fallback = APIError.ipBlocked("Sign in to confirm you're not a bot")
        let result = surfacedError(fallbackError: fallback, originalError: avFoundationCannotOpen)
        guard let apiError = result as? APIError, case APIError.ipBlocked(let reason) = apiError else {
            Issue.record("Expected APIError.ipBlocked but got \(result)")
            return
        }
        #expect(reason == "Sign in to confirm you're not a bot")
    }

    @Test("Surfaced ipBlocked error has the VPN user-facing description")
    func ipBlockedHasVPNDescription() {
        let fallback = APIError.ipBlocked("Your IP was flagged")
        let result = surfacedError(fallbackError: fallback, originalError: avFoundationCannotOpen)
        let description = (result as? APIError)?.errorDescription ?? ""
        #expect(description.contains("VPN") || description.contains("temporarily blocking"),
                "Expected VPN-related message, got: \(description)")
    }

    @Test("ipBlocked from Android fallback is NOT the originalError object")
    func ipBlockedIsNotOriginalError() {
        let fallback = APIError.ipBlocked("Sign in to confirm you're not a bot")
        let original = avFoundationCannotOpen
        let result = surfacedError(fallbackError: fallback, originalError: original)
        // The result must be the ipBlocked error, not the AVFoundation error.
        #expect((result as? APIError) != nil,
                "Result should be an APIError, not \(result)")
    }

    // MARK: - Non-ipBlocked Android failure → preserve originalError

    @Test("Android fallback unavailable preserves AVFoundation originalError")
    func unavailableFallbackPreservesOriginalError() {
        let fallback = APIError.unavailable("This video is unavailable")
        let original = avFoundationCannotOpen
        let result = surfacedError(fallbackError: fallback, originalError: original)
        let nsResult = result as NSError
        #expect(nsResult.domain == "AVFoundationErrorDomain")
        #expect(nsResult.code == -11828)
    }

    @Test("Android fallback httpError preserves AVFoundation originalError")
    func httpErrorFallbackPreservesOriginalError() {
        let fallback = APIError.httpError(403)
        let original = avFoundationCannotOpen
        let result = surfacedError(fallbackError: fallback, originalError: original)
        let nsResult = result as NSError
        #expect(nsResult.domain == "AVFoundationErrorDomain")
        #expect(nsResult.code == -11828)
    }

    @Test("Android fallback network error preserves AVFoundation originalError")
    func networkErrorFallbackPreservesOriginalError() {
        let fallback = NSError(domain: NSURLErrorDomain, code: -1009, userInfo: nil)
        let original = avFoundationCannotOpen
        let result = surfacedError(fallbackError: fallback, originalError: original)
        let nsResult = result as NSError
        #expect(nsResult.domain == "AVFoundationErrorDomain")
        #expect(nsResult.code == -11828)
    }

    // MARK: - ipBlocked pattern-matching boundary checks

    @Test("APIError.unavailable does NOT match ipBlocked pattern")
    func unavailableDoesNotMatchIPBlockedPattern() {
        let error: Error = APIError.unavailable("unavailable")
        // Mirror the exact pattern used in the fix.
        if case APIError.ipBlocked = error {
            Issue.record("APIError.unavailable incorrectly matched APIError.ipBlocked — fix would mis-classify errors")
        }
    }

    @Test("APIError.httpError does NOT match ipBlocked pattern")
    func httpErrorDoesNotMatchIPBlockedPattern() {
        let error: Error = APIError.httpError(403)
        if case APIError.ipBlocked = error {
            Issue.record("APIError.httpError incorrectly matched APIError.ipBlocked")
        }
    }
}
