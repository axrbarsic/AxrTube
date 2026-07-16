import AVFoundation
import iPocketTubeCore

// MARK: - Audio Track Selection (thin wrapper — logic lives in AudioTrackManager)

extension PlaybackViewModel {

    public func selectAudioTrack(_ track: AudioTrack?) {
        audioManager.selectAudioTrack(track)
    }
}
