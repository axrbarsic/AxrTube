import Foundation
import Observation

@MainActor @Observable
public final class FeedLanguageGate {
    public private(set) var approvedIDs: Set<String> = []
    public private(set) var isChecking = false
    public init() {}

    public func check(_ ids: [String], api: any InnerTubeAPIProtocol) async {
        isChecking = true
        defer { isChecking = false }
        let unique = Array(Set(ids))
        for start in stride(from: 0, to: unique.count, by: 4) {
            guard !Task.isCancelled else { return }
            let batch = Array(unique[start..<min(start + 4, unique.count)])
            let accepted = await withTaskGroup(of: (String, Bool).self) { group in
                for id in batch {
                    group.addTask {
                        let evidence = await VideoLanguageEvidenceCache.shared.evidence(for: id) {
                            (try? await api.fetchVideoLanguageEvidence(videoId: id)) ?? .init()
                        }
                        return (id, VideoLanguageClassifier.verdict(for: evidence) == .russian)
                    }
                }
                var result: [String: Bool] = [:]
                for await (id, allowed) in group { result[id] = allowed }
                return result
            }
            guard !Task.isCancelled else { return }
            for (id, allowed) in accepted {
                if allowed { approvedIDs.insert(id) } else { approvedIDs.remove(id) }
            }
        }
    }
}
