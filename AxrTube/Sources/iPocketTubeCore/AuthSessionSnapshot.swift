import Foundation

/// Immutable, versioned authentication state propagated through the app.
///
/// `generation` is monotonic for the lifetime of the process. Consumers must
/// ignore snapshots older than the newest generation they have accepted. This
/// makes sign-out a linear boundary even when older asynchronous work finishes
/// afterwards.
public struct AuthSessionSnapshot: Sendable, Equatable {
    public enum Phase: String, Sendable, Equatable {
        case signedOut
        case signingIn
        case signedIn
        case signingOut
        case secureStoreClearFailed
    }

    public let generation: UInt64
    public let phase: Phase
    public let accessToken: String?
    public let sapisid: String?

    public init(
        generation: UInt64,
        phase: Phase,
        accessToken: String?,
        sapisid: String?
    ) {
        self.generation = generation
        self.phase = phase
        self.accessToken = accessToken
        self.sapisid = sapisid
    }

    public var isSignedIn: Bool {
        phase == .signedIn && (accessToken != nil || sapisid != nil)
    }

    public static func signedOut(generation: UInt64) -> Self {
        .init(generation: generation, phase: .signedOut, accessToken: nil, sapisid: nil)
    }
}
