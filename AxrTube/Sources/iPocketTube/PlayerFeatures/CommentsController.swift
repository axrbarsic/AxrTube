import Foundation
import iPocketTubeCore

// MARK: - Comments
//
// Shared between PlaybackViewModel (standard player) and TOSPlayerViewModel
// (TOS player) — both fetched top-level comments via InnerTubeAPI with an
// identical "skip if already loaded or in flight" guard. `videoId` is
// supplied per call so each adapter can keep its own video-id resolution
// (`(vm.playerInfo?.video ?? video).id` vs. `self.videoId`).

/// Fetches and caches top-level comments for a video.
@MainActor
@Observable
final class CommentsController {

    private(set) var comments: [Comment] = []
    private(set) var isLoading = false

    private let api: InnerTubeAPI
    private let logError: (String) -> Void

    init(api: InnerTubeAPI, logError: @escaping (String) -> Void = { _ in }) {
        self.api = api
        self.logError = logError
    }

    /// Fetches top-level comments for `videoId`. No-op if already loaded or in flight.
    func load(videoId: String) {
        guard comments.isEmpty, !isLoading else { return }
        isLoading = true
        Task {
            do {
                comments = try await api.fetchComments(videoId: videoId)
            } catch {
                logError("fetchComments failed: \(String(describing: error))")
            }
            isLoading = false
        }
    }
}
