import AVFoundation

// MARK: - AVAssetTrackCache
//
// In-memory cache for AVAssetTrack arrays loaded from CDN URLs.
// AVAssetTrack is not Sendable, so this is a final class with NSLock rather
// than an actor — same @unchecked Sendable pattern used by TrackBox elsewhere.
//
// Populated by:
//   • rebuildCompositionForQuality — caches tracks after a successful CDN load
//   • prefetchPreferredQualityTracks — warms the cache in background after initial play
//
// Cleared via clear() whenever a new video is loaded (PlaybackViewModel.load).

final class AVAssetTrackCache: @unchecked Sendable {
    static let shared = AVAssetTrackCache()
    private init() {}

    private let lock = NSLock()
    private var videoMap: [URL: [AVAssetTrack]] = [:]
    private var audioMap: [URL: [AVAssetTrack]] = [:]

    func videoTracks(for url: URL) -> [AVAssetTrack]? {
        lock.withLock { videoMap[url] }
    }

    func audioTracks(for url: URL) -> [AVAssetTrack]? {
        lock.withLock { audioMap[url] }
    }

    func store(videoTracks vt: [AVAssetTrack], audioTracks at: [AVAssetTrack],
               videoURL: URL, audioURL: URL) {
        lock.withLock {
            videoMap[videoURL] = vt
            audioMap[audioURL] = at
        }
    }

    func clear() {
        lock.withLock {
            videoMap.removeAll()
            audioMap.removeAll()
        }
    }
}
