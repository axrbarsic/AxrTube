#if os(iOS)
import AppIntents
import UIKit
import iPocketTubeCore

// MARK: - OpenYouTubeVideoIntent

/// Opens a YouTube video directly in iPocketTube from Siri or the Shortcuts app.
///
/// Siri phrases (registered via ``iPocketTubeShortcuts``):
///   - "Watch on iPocketTube"
///   - "Open YouTube video in iPocketTube"
///   - "Play in iPocketTube"
///
/// The intent extracts the video ID using ``YouTubeLinkHandler`` and fires the
/// existing `ipockettube://video/<id>` deep link, which ``AppEntry.handleOpenURL``
/// already handles — no new playback wiring required.
struct OpenYouTubeVideoIntent: AppIntent {
    static let title: LocalizedStringResource = "Open YouTube Video in iPocketTube"
    static let description = IntentDescription(
        "Opens a YouTube video or Short URL directly in iPocketTube."
    )
    static let openAppWhenRun: Bool = true

    @Parameter(title: "YouTube URL", description: "A YouTube video, Short, or youtu.be URL.")
    var url: URL

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let videoID = YouTubeLinkHandler.videoID(from: url) else {
            throw iPocketTubeIntentError.notYouTubeURL
        }
        guard let deepLink = URL(string: "ipockettube://video/\(videoID)") else {
            throw iPocketTubeIntentError.invalidURL
        }
        await UIApplication.shared.open(deepLink)
        return .result()
    }
}

// MARK: - iPocketTubeShortcuts

/// Registers app shortcuts so they surface in Spotlight and the Shortcuts app
/// automatically — no user setup required (iOS 16.4+).
struct iPocketTubeShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenYouTubeVideoIntent(),
            phrases: [
                "Open YouTube video in \(.applicationName)",
                "Watch on \(.applicationName)",
                "Play in \(.applicationName)"
            ],
            shortTitle: "Open in iPocketTube",
            systemImageName: "play.rectangle"
        )
    }
}

// MARK: - iPocketTubeIntentError

enum iPocketTubeIntentError: LocalizedError {
    case invalidURL
    case notYouTubeURL

    var errorDescription: String? {
        switch self {
        case .invalidURL: "Could not build an iPocketTube deep link."
        case .notYouTubeURL: "The URL doesn't appear to be a YouTube video link."
        }
    }
}
#endif
