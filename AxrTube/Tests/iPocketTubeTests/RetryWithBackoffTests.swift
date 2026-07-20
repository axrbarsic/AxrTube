import Foundation
import Testing
@testable import iPocketTubeCore

// MARK: - RetryWithBackoffTests

@Suite("RetryWithBackoff Pagination")
struct RetryWithBackoffTests {

    // MARK: - Helpers

    /// Transient URLError codes that must trigger a retry.
    private static let transientCodes: [URLError.Code] = [
        .timedOut, .networkConnectionLost, .notConnectedToInternet,
        .cannotConnectToHost, .cannotFindHost, .secureConnectionFailed,
    ]

    // Use near-zero delays so tests complete instantly.
    private let fastInitialDelay: TimeInterval = 0.001
    private let fastMaxDelay: TimeInterval = 0.001

    // MARK: - Tests

    @Test func succeedsImmediatelyWhenNoError() async throws {
        let result = try await retryWithBackoff(
            maxAttempts: 3,
            initialDelay: fastInitialDelay,
            maxDelay: fastMaxDelay
        ) { 42 }

        #expect(result == 42)
    }

    @Test func retriesOnTransientTimedOutThenSucceeds() async throws {
        var callCount = 0
        let result: Int = try await retryWithBackoff(
            maxAttempts: 3,
            initialDelay: fastInitialDelay,
            maxDelay: fastMaxDelay
        ) {
            callCount += 1
            if callCount < 3 { throw URLError(.timedOut) }
            return 99
        }

        #expect(result == 99)
        #expect(callCount == 3)
    }

    @Test(arguments: Self.transientCodes)
    func retriesOnAllTransientURLErrorCodes(code: URLError.Code) async throws {
        var callCount = 0
        let result: String = try await retryWithBackoff(
            maxAttempts: 2,
            initialDelay: fastInitialDelay,
            maxDelay: fastMaxDelay
        ) {
            callCount += 1
            if callCount == 1 { throw URLError(code) }
            return "ok"
        }

        #expect(result == "ok")
        #expect(callCount == 2)
    }

    @Test func exhaustsRetriesAndThrowsOnAllTransientFailures() async throws {
        var callCount = 0
        await #expect(throws: URLError.self) {
            try await retryWithBackoff(
                maxAttempts: 3,
                initialDelay: fastInitialDelay,
                maxDelay: fastMaxDelay
            ) {
                callCount += 1
                throw URLError(.timedOut)
            }
        }

        #expect(callCount == 3)
    }

    @Test func doesNotRetryOnNonTransientURLError() async throws {
        var callCount = 0
        await #expect(throws: URLError.self) {
            try await retryWithBackoff(
                maxAttempts: 3,
                initialDelay: fastInitialDelay,
                maxDelay: fastMaxDelay
            ) {
                callCount += 1
                throw URLError(.cancelled)
            }
        }

        // Must stop after exactly 1 attempt — no retry for non-transient codes.
        #expect(callCount == 1)
    }

    @Test func doesNotRetryOnNonURLError() async throws {
        enum SomeError: Error { case permanent }
        var callCount = 0
        await #expect(throws: SomeError.self) {
            try await retryWithBackoff(
                maxAttempts: 3,
                initialDelay: fastInitialDelay,
                maxDelay: fastMaxDelay
            ) {
                callCount += 1
                throw SomeError.permanent
            }
        }

        #expect(callCount == 1)
    }

    @Test func doesNotRetryOnCancellationError() async throws {
        var callCount = 0
        await #expect(throws: CancellationError.self) {
            try await retryWithBackoff(
                maxAttempts: 3,
                initialDelay: fastInitialDelay,
                maxDelay: fastMaxDelay
            ) {
                callCount += 1
                throw CancellationError()
            }
        }

        #expect(callCount == 1)
    }

    @Test func respectsMaxAttemptsLimit() async throws {
        var callCount = 0
        await #expect(throws: URLError.self) {
            try await retryWithBackoff(
                maxAttempts: 2,
                initialDelay: fastInitialDelay,
                maxDelay: fastMaxDelay
            ) {
                callCount += 1
                throw URLError(.networkConnectionLost)
            }
        }

        #expect(callCount == 2)
    }
}
