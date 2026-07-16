import Foundation

extension AuthService {

    // MARK: - Retry

    /// Retries `operation` up to `maxAttempts` times on transient URLErrors,
    /// using exponential backoff. Permanent OAuth and parsing errors are thrown
    /// immediately without retrying. Task cancellation propagates immediately.
    @discardableResult
    func retryWithBackoff<T>(
        maxAttempts: Int = 3,
        initialDelay: TimeInterval = 1.0,
        maxDelay: TimeInterval = 10.0,
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
                authLog.notice("retryWithBackoff: attempt \(attempt)/\(maxAttempts) failed (\(urlError.code.rawValue)), retrying in \(Int(delay))s")
                lastError = urlError
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                delay = min(delay * 2, maxDelay)
            } catch {
                throw error
            }
        }
        throw lastError ?? URLError(.timedOut)
    }

    // MARK: - Helpers

    func formEncode(_ params: [String: String]) -> Data? {
        params.map { k, v in
            let ek = k.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? k
            let ev = v.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? v
            return "\(ek)=\(ev)"
        }
        .joined(separator: "&")
        .data(using: .utf8)
    }
}
