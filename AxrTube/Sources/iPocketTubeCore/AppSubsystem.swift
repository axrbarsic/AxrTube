import Foundation

/// Logging subsystem string derived from the app's bundle identifier at runtime.
package let appSubsystem: String = Bundle.main.bundleIdentifier ?? "com.void.ipockettube.app"
