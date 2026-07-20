import Foundation

/// The terminal result of waiting for an already-running fallback task.
public enum BoundedTaskWaitResult<Value: Sendable>: Sendable {
    case value(Value)
    case timedOut
}

private actor FirstResultGate<Value: Sendable> {
    private var bufferedResult: Value?
    private var continuation: CheckedContinuation<Value, Never>?
    private var isResolved = false

    func resolve(_ result: Value) {
        guard !isResolved else { return }
        isResolved = true
        if let continuation {
            self.continuation = nil
            continuation.resume(returning: result)
        } else {
            bufferedResult = result
        }
    }

    func wait() async -> Value {
        if let bufferedResult {
            self.bufferedResult = nil
            return bufferedResult
        }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }
}

/// Waits for an unstructured task without making the caller inherit that task's full lifetime.
///
/// A structured task group cannot be used here: cancelling a child that is awaiting
/// `Task.value` does not cancel the underlying task, so the group still waits for it on scope
/// exit. This one-shot gate lets the caller proceed on the deadline while the shared producer
/// finishes harmlessly in the background.
public enum BoundedTaskWait {
    public static func value<Value: Sendable>(
        from task: Task<Value, Never>,
        timeoutNanoseconds: UInt64
    ) async -> BoundedTaskWaitResult<Value> {
        let gate = FirstResultGate<BoundedTaskWaitResult<Value>>()
        let valueWaiter = Task {
            let value = await task.value
            await gate.resolve(.value(value))
        }
        let timeoutWaiter = Task {
            do {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
            } catch {
                return
            }
            await gate.resolve(.timedOut)
        }

        let result = await gate.wait()
        valueWaiter.cancel()
        timeoutWaiter.cancel()
        return result
    }
}

/// Policy for the early WKWebView branch of the playback fallback race.
public enum PlaybackFallbackPolicy {
    /// The extractor itself may keep warming for longer, but it must not hold the entire
    /// fallback state machine (and its spinner) hostage.
    public static let earlyWebViewWaitNanoseconds: UInt64 = 10_000_000_000

    public static func shouldAttemptSerialWebView(
        permissionDenied: Bool,
        earlyWaitTimedOut: Bool
    ) -> Bool {
        !permissionDenied && !earlyWaitTimedOut
    }
}

/// Produces a stream-source summary suitable for public unified logs.
/// Query values, paths, cookies and signed CDN tokens are deliberately omitted.
public enum PlaybackURLDiagnostics {
    public static func safeSummary(_ url: URL?) -> String {
        guard let url else { return "none" }

        let scheme = url.scheme?.lowercased() ?? "unknown"
        let rawHost = url.host?.lowercased() ?? "none"
        let host: String
        if rawHost == "youtube.com" || rawHost.hasSuffix(".youtube.com") {
            host = "youtube.com"
        } else if rawHost == "googlevideo.com" || rawHost.hasSuffix(".googlevideo.com") {
            host = "googlevideo.com"
        } else if rawHost == "googleapis.com" || rawHost.hasSuffix(".googleapis.com") {
            host = "googleapis.com"
        } else if scheme == "file" {
            host = "local"
        } else {
            host = "other"
        }

        let ext = url.pathExtension.lowercased()
        let queryNames = Set(URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.map { $0.name.lowercased() } ?? [])
        var flags: [String] = []
        for name in ["rqh", "pot", "spc", "expire", "n", "sig", "signature"] where queryNames.contains(name) {
            flags.append(name)
        }

        let extPart = ext.isEmpty ? "none" : ext
        let flagPart = flags.isEmpty ? "none" : flags.joined(separator: ",")
        return "scheme=\(scheme) host=\(host) ext=\(extPart) queryFlags=\(flagPart)"
    }
}
