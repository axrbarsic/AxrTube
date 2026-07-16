import Foundation
import Testing
@testable import iPocketTubeCore

@Suite("Playback fallback deadline and safe diagnostics")
struct PlaybackFallbackPolicyTests {
    @Test("ready shared task wins before the deadline")
    func readyTaskWins() async {
        let task = Task { "ready" }
        let result = await BoundedTaskWait.value(from: task, timeoutNanoseconds: 100_000_000)
        guard case .value(let value) = result else {
            Issue.record("Expected the task value, not a timeout")
            return
        }
        #expect(value == "ready")
    }

    @Test("hung shared task releases the fallback state machine on deadline")
    func hungTaskTimesOut() async {
        let task = Task {
            try? await Task.sleep(nanoseconds: 100_000_000)
            return "late"
        }
        let result = await BoundedTaskWait.value(from: task, timeoutNanoseconds: 5_000_000)
        guard case .timedOut = result else {
            Issue.record("Expected the bounded wait to time out")
            return
        }
        #expect(!PlaybackFallbackPolicy.shouldAttemptSerialWebView(
            permissionDenied: false,
            earlyWaitTimedOut: true
        ))
    }

    @Test("serial extraction remains available after a quick ordinary failure")
    func ordinaryFailureAllowsSerialFallback() {
        #expect(PlaybackFallbackPolicy.shouldAttemptSerialWebView(
            permissionDenied: false,
            earlyWaitTimedOut: false
        ))
        #expect(!PlaybackFallbackPolicy.shouldAttemptSerialWebView(
            permissionDenied: true,
            earlyWaitTimedOut: false
        ))
    }

    @Test("stream diagnostics omit signed path and query values")
    func streamSummaryIsSafe() throws {
        let url = try #require(URL(string:
            "https://rr1---sn-secret.googlevideo.com/videoplayback/private/path/file.mp4?rqh=1&pot=SECRET_TOKEN&sig=SECRET_SIGNATURE&expire=999999"
        ))
        let summary = PlaybackURLDiagnostics.safeSummary(url)

        #expect(summary.contains("host=googlevideo.com"))
        #expect(summary.contains("ext=mp4"))
        #expect(summary.contains("rqh"))
        #expect(summary.contains("pot"))
        #expect(!summary.contains("SECRET"))
        #expect(!summary.contains("private/path"))
        #expect(!summary.contains("999999"))
        #expect(!summary.contains("rr1---sn-secret"))
    }
}
