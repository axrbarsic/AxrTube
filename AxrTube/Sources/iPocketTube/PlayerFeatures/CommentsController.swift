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

    /// The video the current `comments` belong to.
    private(set) var videoId: String?
    private var loadTask: Task<Void, Never>?

    /// Fetches top-level comments for `videoId`. No-op if that video's comments
    /// are already loaded or in flight; a different video discards the old list
    /// so one video's comments never appear under another.
    func load(videoId: String) {
        if videoId == self.videoId, !comments.isEmpty || isLoading { return }
        loadTask?.cancel()
        self.videoId = videoId
        comments = []
        isLoading = true
        let api = api
        loadTask = Task { [weak self] in
            let result: [Comment]
            do {
                result = try await api.fetchComments(videoId: videoId)
            } catch {
                guard let self, self.videoId == videoId else { return }
                self.logError("fetchComments failed: \(String(describing: error))")
                self.isLoading = false
                return
            }
            guard let self, !Task.isCancelled, self.videoId == videoId else { return }
            self.comments = result
            self.isLoading = false
        }
    }
}
