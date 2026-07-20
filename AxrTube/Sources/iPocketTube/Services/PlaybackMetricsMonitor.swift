#if os(iOS) && canImport(MetricKit)
import Foundation
import MetricKit

/// Device-only, local MetricKit intake. It records only payload counts in the
/// sanitized playback journal; no MetricKit payload or user data leaves iPocketTube.
public enum PlaybackMetricsMonitor {
    public static func start() {
        PlaybackMetricSubscriber.shared.start()
    }
}

private final class PlaybackMetricSubscriber: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    static let shared = PlaybackMetricSubscriber()
    private let lock = NSLock()
    private var started = false

    func start() {
        lock.lock()
        defer { lock.unlock() }
        guard !started else { return }
        started = true
        MXMetricManager.shared.add(self)
    }

    func didReceive(_ payloads: [MXMetricPayload]) {
        AudioDiagnostics.shared.record(
            source: "metrickit",
            event: "metricPayload.received",
            decision: "count=\(payloads.count)"
        )
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        AudioDiagnostics.shared.record(
            source: "metrickit",
            event: "diagnosticPayload.received",
            decision: "count=\(payloads.count)"
        )
    }
}
#endif
