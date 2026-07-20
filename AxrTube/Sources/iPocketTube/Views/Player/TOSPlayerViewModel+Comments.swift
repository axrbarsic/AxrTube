#if !os(tvOS)
import Foundation

// MARK: - Comments
//
// Transferred from PlayerView+Overlays.swift's loadComments() — a pure
// InnerTubeAPI fetch with zero AVPlayer dependency. The empty/in-flight guard
// that PlayerView+Overlays' moreMenuCommentsRow applies at the call site is
// handled inside CommentsController.load(videoId:) instead.

extension TOSPlayerViewModel {

    /// Fetches top-level comments for the current video (no-op if already
    /// loaded or a fetch is in flight).
    func loadComments() {
        comments.load(videoId: videoId)
    }
}
#endif // !os(tvOS)
