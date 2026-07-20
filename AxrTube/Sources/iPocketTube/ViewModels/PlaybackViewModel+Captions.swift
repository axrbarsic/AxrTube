import Foundation
import iPocketTubeCore

// MARK: - Caption Track Selection (thin wrapper — logic lives in CaptionsManager)

extension PlaybackViewModel {

    func transcriptBookMetadata(for video: Video) -> TranscriptBookMetadata {
        TranscriptBookMetadata(
            videoID: video.id,
            title: video.title,
            channelTitle: video.channelTitle,
            duration: video.duration
        )
    }

    public func selectCaption(_ track: CaptionTrack?) {
        captionsManager.selectCaption(track, currentTime: currentTime)
        // Persist the user's choice so it can be re-applied to the next video.
        // nil means "captions off" and clears the preference.
        settings.preferredCaptionLanguage = track?.languageCode
    }

    func updateCaptionCue(for time: TimeInterval) {
        captionsManager.updateCaptionCue(for: time)
    }

    /// Applies the saved caption language preference to the available tracks.
    /// The same owner also loads one automatic transcript track when the overlay
    /// is off, so opening the transcript never starts a second captions fetch.
    func autoApplyCaptionPreference(tracks: [CaptionTrack]) {
        guard let identity = captionsManager.activePlaybackIdentity else {
            captionsManager.availableCaptions = tracks
            return
        }
        _ = captionsManager.applyAvailableCaptions(
            tracks,
            for: identity,
            preferredLanguage: settings.preferredCaptionLanguage,
            currentTime: currentTime
        )
    }
}
