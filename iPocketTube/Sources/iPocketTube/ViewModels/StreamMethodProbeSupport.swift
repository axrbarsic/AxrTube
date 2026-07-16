import Foundation

// MARK: - StreamMethodProbeSupport

/// Lightweight testing support for `--uitesting-force-stream-method=<method>`.
///
/// When set (via `AppEntry.swift` parsing the launch argument), `exhaustiveRetry`
/// in `PlaybackViewModel+Fallback` calls `probeStreamMethod(_:video:)` instead of
/// running the full race + serial chain.  This lets UI tests exercise exactly one
/// stream-fetching client per test run, so we can build a per-video × per-method
/// compatibility matrix.
///
/// This type is intentionally minimal — no dependencies, no Swift concurrency
/// isolation.  It is written once at app launch and then only read.
public enum StreamMethodProbeSupport {

    // nonisolated(unsafe): written synchronously on the main thread during app init
    // before any concurrent code runs; after that it is read-only.
    nonisolated(unsafe) public static var forcedStreamMethod: String? = nil

    /// Valid method identifiers accepted by `probeStreamMethod(_:video:)`.
    public static let knownMethods: [String] = [
        "ios",
        "ios-auth",
        "tvembedded",
        "tvauth",
        "websafari",
        "mweb",
        "android",
        "android-vr",
        "web-creator",
        "web-auth",
        "wkwebview-hls",
    ]
}
