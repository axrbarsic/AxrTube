#if os(iOS)
import SwiftUI
import iPocketTubeCore

/// Live strip under the playing «Скачанные» row: play/pause, the audio
/// amplitude scope and a seek bar (kept from the original download cards).
struct YTDownloadNowPlaying: View {
    let vm: PlaybackViewModel

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Button {
                iPocketTubeHaptics.shared.perform(.playbackTransport)
                vm.togglePlayPause()
            } label: {
                Image(systemName: vm.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(YTColor.chipSelectedText)
                    .frame(width: 40, height: 40)
                    .background(YTColor.chipSelected, in: Circle())
            }
            .buttonStyle(YTPressStyle())
            .accessibilityLabel(vm.isPlaying ? "Пауза" : "Воспроизвести")
            AudioWaveformView(
                videoID: vm.currentVideo?.id ?? "",
                playbackTime: vm.isScrubbing ? vm.scrubTime : vm.currentTime,
                duration: vm.duration,
                bufferedProgress: 0,
                isPlaying: vm.isPlaying,
                isScrubbing: vm.isScrubbing,
                onScrubBegan: { vm.beginScrubbing() },
                onScrubChanged: { vm.updateScrub(to: $0) },
                onScrubEnded: {
                    iPocketTubeHaptics.shared.perform(.seekCommit)
                    vm.commitScrub()
                }
            )
        }
        .padding(10)
        .background(YTColor.chip, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .accessibilityIdentifier("downloads.nowPlaying")
    }
}
#endif
