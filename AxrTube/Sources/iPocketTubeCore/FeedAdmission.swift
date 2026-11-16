import Foundation

/// Decides which fetched videos may enter a feed. It runs before a page is
/// committed, so a feed changes once per page instead of rebuilding while
/// per-video checks finish.
public struct FeedAdmission: Sendable {
    /// Identifies the policy; a different key means the feed must reload.
    public let key: String
    private let filter: @Sendable ([Video]) async -> [Video]

    public init(key: String, filter: @escaping @Sendable ([Video]) async -> [Video]) {
        self.key = key
        self.filter = filter
    }

    public func admit(_ videos: [Video]) async -> [Video] {
        await filter(videos)
    }

    public static let all = FeedAdmission(key: "all") { $0 }

    /// Keeps only videos whose language evidence is verified Russian, in
    /// service order. Unknown language is rejected, as in the feed gate.
    public static func russianOnly(api: any InnerTubeAPIProtocol, concurrency: Int = 8) -> FeedAdmission {
        FeedAdmission(key: "ru") { videos in
            var russian = Set<String>()
            var start = videos.startIndex
            while start < videos.endIndex {
                if Task.isCancelled { return [] }
                let end = min(start + max(concurrency, 1), videos.endIndex)
                let batch = videos[start..<end].map(\.id)
                await withTaskGroup(of: (String, Bool).self) { group in
                    for id in batch {
                        group.addTask {
                            let evidence = await VideoLanguageEvidenceCache.shared.evidence(for: id) {
                                (try? await api.fetchVideoLanguageEvidence(videoId: id)) ?? .init()
                            }
                            return (id, VideoLanguageClassifier.verdict(for: evidence) == .russian)
                        }
                    }
                    for await (id, allowed) in group where allowed { russian.insert(id) }
                }
                start = end
            }
            return videos.filter { russian.contains($0.id) }
        }
    }
}
