import Foundation
import iPocketTubeCore

enum PlaylistDownloadEvent: Sendable {
    case restored(videoID: String, progress: Double)
    case progress(videoID: String, progress: Double)
    case completed(videoID: String, location: URL)
    case failed(videoID: String, source: PlaylistTaskIdentity.Kind, message: String, errorCode: Int = 0, httpStatus: Int? = nil)
    case waiting(videoID: String)

    var videoID: String {
        switch self {
        case .restored(let id, _), .progress(let id, _), .completed(let id, _): id
        case .failed(let id, _, _, _, _): id
        case .waiting(let id): id
        }
    }
}


/// Native transfers publish observations; only the coordinator owns queue state.
protocol PlaylistDownloadTransport: AnyObject, Sendable {
    var onEvent: (@Sendable (PlaylistDownloadEvent, UInt64) -> Void)? { get set }
    func startFile(video: Video, url: URL, userAgent: String)
    func startHLS(video: Video, url: URL, userAgent: String)
    func cancel(videoID: String)
    func isCurrent(_ videoID: String, generation: UInt64) -> Bool
    func restoreTasks(completion: @escaping @Sendable (Set<String>) -> Void)
    func setPlaybackPressure(_ pressured: Bool)
}

struct ResolvedOfflineSource: Sendable {
    let media: PlaylistMediaSource
    let userAgent: String
}

enum OfflineSourceRequest: Sendable {
    case preferred
    case refreshedFile
}

typealias OfflineSourceResolver = @Sendable (Video, OfflineSourceRequest) async throws -> ResolvedOfflineSource
