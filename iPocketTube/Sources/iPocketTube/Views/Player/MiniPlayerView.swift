#if os(iOS)
import SwiftUI
import AVFoundation
import UIKit
import iPocketTubeCore

// MARK: - MiniPlayerView

/// Compact bar overlaid at the bottom of MainTabView when the player is minimized.
/// Shows a live video thumbnail (the shared PersistentPlayerHostView), title,
/// channel, play/pause button, and a close button.
/// Tapping the bar expands back to full-screen.
struct MiniPlayerView: View {
    @Environment(PlayerStateStore.self) private var playerState
    @Environment(PlayerRouter.self) private var playerRouter

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                AsyncImage(url: playerRouter.audioFirst.currentVideo?.thumbnailURL) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFill()
                    } else {
                        ZStack {
                            Color.secondary.opacity(0.16)
                            Image(systemName: "waveform")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(width: 58, height: 58)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text(playerRouter.audioFirst.currentVideo?.title ?? "")
                        .font(.caption.weight(.semibold))
                        .lineLimit(2)
                        .foregroundStyle(.primary)
                        .accessibilityIdentifier("miniPlayer.titleLabel")
                    Text(playerRouter.audioFirst.statusText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .accessibilityIdentifier("miniPlayer.audioStatus")
                }

                Spacer(minLength: 0)

                Button {
                    iPocketTubeHaptics.shared.perform(.playbackTransport)
                    playerState.vm.togglePlayPause()
                } label: {
                    Image(systemName: playerState.vm.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.primary)
                        .frame(width: 44, height: 44)
                }
                .iPocketTubeLiquidButtonStyle()
                .disabled(playerState.vm.player.currentItem == nil)
                .contentShape(Rectangle())
                .accessibilityIdentifier("miniPlayer.playPauseButton")

                Button {
                    iPocketTubeHaptics.shared.perform(.primaryAction)
                    playerRouter.closeAudioFirst()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                }
                .iPocketTubeLiquidButtonStyle()
                .contentShape(Rectangle())
                .accessibilityIdentifier("miniPlayer.closeButton")
            }
            .padding(.horizontal, 6)

            ZStack(alignment: .leading) {
                Rectangle().fill(Color.secondary.opacity(0.15))
                Rectangle()
                    .fill(iPocketTubeVisualTokens.mintSoft.opacity(0.45))
                    .scaleEffect(x: playerRouter.audioFirst.bufferedProgress, anchor: .leading)
                Rectangle()
                    .fill(iPocketTubeVisualTokens.mint)
                    .scaleEffect(x: playerRouter.audioFirst.downloadProgress, anchor: .leading)
            }
            .frame(height: 3)
            .accessibilityElement()
            .accessibilityLabel("Audio download progress")
            .accessibilityValue("\(Int(playerRouter.audioFirst.downloadProgress * 100)) percent")
            .accessibilityIdentifier("miniPlayer.downloadProgress")
        }
        .frame(height: 70)
        .iPocketTubeGlassSurface(cornerRadius: 20, interactive: true)
        .padding(.horizontal, 8)
        .padding(.bottom, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("miniPlayer.bar")
    }
}

#endif
