import Foundation

// MARK: - AuthError

public enum AuthError: LocalizedError {
    case cancelled
    case missingCode
    case tokenExchangeFailed
    case notSignedIn
    case configurationError
    case deviceCodeRequestFailed
    case authorizationPending
    case slowDown
    case deviceCodeExpired

    public var errorDescription: String? {
        switch self {
        case .cancelled:              return "Sign-in was cancelled"
        case .missingCode:            return "OAuth code was missing from callback"
        case .tokenExchangeFailed:    return "Failed to exchange code for tokens"
        case .notSignedIn:            return "You are not signed in"
        case .configurationError:     return "OAuth credentials could not be obtained"
        case .deviceCodeRequestFailed:return "Could not start sign-in. Check your internet connection."
        case .authorizationPending:   return "Waiting for authorisation…"
        case .slowDown:               return "Too many requests — slowing down"
        case .deviceCodeExpired:      return "The sign-in code expired. Please try again."
        }
    }
}
