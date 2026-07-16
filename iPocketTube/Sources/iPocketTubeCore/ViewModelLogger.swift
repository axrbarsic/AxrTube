import Foundation
import os

// MARK: - ViewModelLogger
//
// Foundation-only logger for ViewModels that live in iPocketTubeCore.
// Matches the CrashlyticsLogger interface so moved ViewModels need only
// a type-name substitution.  In production the iPocketTube layer wires
// up Crashlytics separately via its own CrashlyticsLogger.

struct ViewModelLogger: Sendable {
    private let logger: Logger

    init(subsystem: String = appSubsystem, category: String) {
        logger = Logger(subsystem: subsystem, category: category)
    }

    func notice(_ message: String) {
        logger.notice("\(message, privacy: .public)")
    }

    func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
    }

    func debug(_ message: String) {
        logger.debug("\(message, privacy: .public)")
    }
}
