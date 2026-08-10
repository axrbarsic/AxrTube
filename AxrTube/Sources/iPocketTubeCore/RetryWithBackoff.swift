import Foundation

private let retryLog = ViewModelLogger(category: "RetryWithBackoff")

/// Retries `operation` up to `maxAttempts` times on transient URLErrors,
/// using exponential backoff. Permanent errors (e.g. `APIError`, decoding
/// failures) and Task cancellation are propagated immediately without retrying.
///
/// Inherits the caller's actor isolation via `#isolation` (SE-0420) so closures
/// captured from `@MainActor` contexts need not be `@Sendable`.
///
/// Used by all pagination entry points (BrowseViewModel, HomeViewModel,
/// SearchViewModel, PlaylistViewModel, ChannelViewModel) to survive brief
/// network interruptions without dropping the user's scroll position.
@discardableResult
func retryWithBackoff<T>(
    label: String = "",
    maxAttempts: Int = 3,
    initialDelay: TimeInterval = 1.0,
    maxDelay: TimeInterval = 10.0,
    isolation: isolated (any Actor)? = #isolation,
    _ operation: () async throws -> T
) async throws -> T {
    let transientCodes: [URLError.Code] = [
        .timedOut, .networkConnectionLost, .notConnectedToInternet,
        .cannotConnectToHost, .cannotFindHost, .secureConnectionFailed,
    ]
    var delay = initialDelay
    var lastError: (any Error)?
    for attempt in 1...maxAttempts {
        do {
            return try await operation()
        } catch let urlError as URLError
                where transientCodes.contains(urlError.code) && attempt < maxAttempts {
            let tag = label.isEmpty ? "" : "[\(label)] "
            retryLog.notice("\(tag)attempt \(attempt)/\(maxAttempts) failed (\(urlError.code.rawValue)), retrying in \(Int(delay))s")
            lastError = urlError
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            delay = min(delay * 2, maxDelay)
        } catch let apiError as APIError {
            // YouTube rate-limits anonymous clients (429) and gateways may
            // briefly 5xx; both are transient and worth a bounded retry.
            guard case .httpError(let statusCode) = apiError,
                  statusCode == 408 || statusCode == 429 || (500...599).contains(statusCode) else {
                throw apiError
            }
            guard attempt < maxAttempts else {
                lastError = apiError
                break
            }
            let tag = label.isEmpty ? "" : "[\(label)] "
            retryLog.notice("\(tag)attempt \(attempt)/\(maxAttempts) failed (HTTP \(statusCode)), retrying in \(Int(delay))s")
            lastError = apiError
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            delay = min(delay * 2, maxDelay)
        } catch {
            throw error
        }
    }
    throw lastError ?? URLError(.timedOut)
}
