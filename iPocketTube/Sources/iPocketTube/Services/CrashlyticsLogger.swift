import Foundation
import os
import iPocketTubeCore

/// Local diagnostic logger used by personal builds.
///
/// The public interface intentionally matches the former Crashlytics-backed logger
/// so playback and download diagnostics keep working without requiring a Firebase
/// project or bundling user activity with a third-party analytics service.
struct CrashlyticsLogger: Sendable {

    /// Short identifier (8 hex chars) generated once per app session.
    /// Displayed in Stats for Nerds and included in local diagnostic log entries.
    static let sessionReportID: String = {
        let raw = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        return String(raw.prefix(8)).uppercased()
    }()
    private static let diagnosticLogger = Logger(subsystem: appSubsystem, category: "Diagnostics")
    private let logger: Logger
    private let category: String

    init(subsystem: String = appSubsystem, category: String) {
        logger = Logger(subsystem: subsystem, category: category)
        self.category = category
    }

    func notice(_ message: @autoclosure () -> String) {
        let msg = message()
        logger.notice("\(msg, privacy: .public)")
    }

    func error(_ message: @autoclosure () -> String) {
        let msg = message()
        logger.error("\(msg, privacy: .public)")
    }

    func debug(_ message: @autoclosure () -> String) {
        let msg = message()
        logger.debug("\(msg, privacy: .public)")
        // Not forwarded — too verbose for crash reports
    }

    /// Records a surfaced non-fatal error in the local unified log.
    func recordNonFatal(_ error: Error, userInfo: [String: String] = [:]) {
        let nsError = error as NSError
        let context = userInfo.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " ")
        let msg = "[\(category)] \(nsError.domain)(\(nsError.code)): \(nsError.localizedDescription) \(context)"
        logger.error("\(msg, privacy: .public)")
    }

    /// Stamps the video currently being loaded onto Crashlytics' persistent custom keys.
    /// Called once per `load(video:)` so that both crashes and non-fatals show which
    /// video was active at the time of the failure.
    static func setVideoContext(id: String, title: String) {
        diagnosticLogger.debug("active_video_id=\(id, privacy: .public) title=\(title.prefix(120), privacy: .public)")
    }

    /// Stamps the video the user *intended* to play onto Crashlytics' persistent custom keys.
    /// Called from `PlayerStateStore.play(video:)` — the earliest user-intent signal —
    /// so it is set BEFORE `load(video:)` runs and before the breadcrumb buffer can fill.
    /// Comparing `intended_video_id` with `active_video_id` in a report reveals whether
    /// the wrong video was loaded (prefetch race / wrong-card tap / id mismatch).
    static func setIntendedVideo(id: String, title: String) {
        diagnosticLogger.debug("intended_video_id=\(id, privacy: .public) title=\(title.prefix(120), privacy: .public)")
    }

    /// Records a user-triggered diagnostic non-fatal event in Crashlytics.
    /// All breadcrumbs accumulated during the session are attached to this event,
    /// giving a detailed picture of the app flow leading up to the user's report.
    /// The `report_id` custom key matches the ID shown in the Stats for Nerds
    /// debug overlay (two-finger tap in the player) so reports can be correlated
    /// with user-provided IDs from support conversations.
    static func sendDiagnosticReport() {
        diagnosticLogger.notice("User-requested diagnostic report id=\(sessionReportID, privacy: .public)")
    }

    /// Records a non-fatal Crashlytics event when time-to-first-frame exceeds 4 seconds.
    /// Surfaces in the Firebase console under domain `iPocketTube.SlowLoad` (code 4001),
    /// tagged with the stream type and elapsed ms so we can correlate slow-load rate
    /// with fallback path and network conditions.
    static func recordSlowVideoLoad(
        videoId: String,
        elapsedMs: Int,
        streamType: String,
        hasError: Bool,
        errorDescription: String? = nil
    ) {
        let detail = errorDescription ?? "none"
        diagnosticLogger.error("slow_load video=\(videoId, privacy: .public) ttff_ms=\(elapsedMs) stream=\(streamType, privacy: .public) has_error=\(hasError) detail=\(detail, privacy: .public)")
    }

    /// Automatically records a diagnostic report when playback fails and the error is
    /// shown to the user. Uses domain `iPocketTube.AutoDiagnostic` (code 1) so it appears
    /// as a distinct Firebase issue from user-triggered reports, making it easy to query
    /// "all sessions where a user couldn't play a video" without manual intervention.
    /// Custom keys set by `recordNonFatal` (stream_url, has_retried, etc.) are already
    /// stamped on the Crashlytics instance and are automatically attached to this event.
    static func sendAutoPlaybackDiagnostic() {
        diagnosticLogger.error("Automatic playback failure diagnostic")
    }

    /// Records a non-fatal Crashlytics event when the video that reached readyToPlay
    /// (`activeId`) does not match the video the user intended to play (`intendedId`).
    /// Surfaces in Firebase under domain `iPocketTube.WrongVideo` (code 2) so
    /// wrong-video regressions can be queried independently of user-triggered reports.
    /// Custom keys `wv_intended_id` / `wv_active_id` make it easy to see both IDs
    /// in the Firebase console without opening the full breadcrumb log.
    static func sendWrongVideoReport(
        intendedId: String,
        intendedTitle: String,
        activeId: String,
        activeTitle: String
    ) {
        let msg = "[WrongVideo] intended=\(intendedId) (\(intendedTitle.prefix(60))) active=\(activeId) (\(activeTitle.prefix(60)))"
        Logger(subsystem: appSubsystem, category: "WrongVideo").error("\(msg, privacy: .public)")
    }
}
