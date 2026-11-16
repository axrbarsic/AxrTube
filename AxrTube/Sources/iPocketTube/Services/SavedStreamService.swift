import Foundation
import iPocketTubeCore

/// «Скачать» on the watch page: saves the video from the stream cache
/// (what is already downloaded is kept, the rest is completed in the
/// background) and resumes unfinished saves on launch.
@MainActor
enum SavedStreamService {
    private static var configured = false

    /// Wires URL refresh and starts finishing pending saves. Idempotent.
    static func start(api: InnerTubeAPI) {
        if !configured {
            configured = true
            Task {
                await PinnedStreamCompleter.shared.setResolver { videoID in
                    guard let info = try? await api.fetchStartupPlayerInfo(videoId: videoID),
                          let hls = info.hlsURL else { return nil }
                    return StreamSource(master: hls, headers: [
                        "User-Agent": InnerTubeClients.Web.userAgent,
                        "Origin": "https://www.youtube.com",
                        "Referer": "https://www.youtube.com/",
                    ])
                }
            }
        }
        resume()
    }

    static func resume() {
        let library = PinnedStreamLibrary.shared
        guard !library.pending.isEmpty else { return }
        Task {
            await PinnedStreamCompleter.shared.start(
                pending: { await MainActor.run { library.pending } },
                report: { id, progress, complete in
                    await library.update(id, progress: progress, isComplete: complete)
                }
            )
        }
    }

    static func pin(_ video: Video, cachedFraction: Double, isComplete: Bool) {
        Task {
            await PinnedStreamLibrary.shared.pin(video, progress: cachedFraction, isComplete: isComplete)
            resume()
        }
    }

    static func remove(_ videoID: String) {
        Task { await PinnedStreamLibrary.shared.remove(videoID) }
    }
}
