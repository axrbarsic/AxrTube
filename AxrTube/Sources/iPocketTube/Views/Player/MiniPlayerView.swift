#if os(iOS)
import SwiftUI
import AVFoundation
import UIKit
import iPocketTubeCore

// MARK: - Shared Now Playing accessory

struct NowPlayingAccessoryChrome<Artwork: View>: View {
    let title: String
    let isPlaying: Bool
    let canTogglePlayback: Bool
    let openDetails: () -> Void
    let togglePlayback: () -> Void
    let close: () -> Void
    let openTranscript: (() -> Void)?
    @ViewBuilder let artwork: () -> Artwork

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    init(
        title: String,
        isPlaying: Bool,
        canTogglePlayback: Bool,
        openDetails: @escaping () -> Void,
        togglePlayback: @escaping () -> Void,
        close: @escaping () -> Void,
        openTranscript: (() -> Void)? = nil,
        @ViewBuilder artwork: @escaping () -> Artwork
    ) {
        self.title = title
        self.isPlaying = isPlaying
        self.canTogglePlayback = canTogglePlayback
        self.openDetails = openDetails
        self.togglePlayback = togglePlayback
        self.close = close
        self.openTranscript = openTranscript
        self.artwork = artwork
    }

    var body: some View {
        HStack(spacing: 6) {
            Button(action: openDetails) {
                HStack(spacing: 10) {
                    artwork()
                        .frame(width: 42, height: 42)
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .accessibilityHidden(true)

                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityHint("Открыть текущую загрузку")
            .accessibilityIdentifier("nowPlayingAccessory.detailsButton")

            Button(action: togglePlayback) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canTogglePlayback)
            .accessibilityLabel(isPlaying ? "Пауза" : "Воспроизвести")
            .accessibilityIdentifier("nowPlayingAccessory.playPauseButton")

            if let openTranscript {
                Button(action: openTranscript) {
                    Text("Стенограмма")
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .padding(.horizontal, 6)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red)
                .accessibilityLabel("Открыть стенограмму")
                .accessibilityIdentifier("nowPlayingAccessory.transcriptButton")
            }

            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Закрыть")
            .accessibilityIdentifier("nowPlayingAccessory.closeButton")
        }
        .frame(minHeight: 52)
        .padding(.horizontal, 8)
        .modifier(NowPlayingAccessoryFallbackSurface(
            reduceTransparency: reduceTransparency,
            increasedContrast: contrast == .increased
        ))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("nowPlayingAccessory.bar")
    }
}

private struct NowPlayingAccessoryFallbackSurface: ViewModifier {
    let reduceTransparency: Bool
    let increasedContrast: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
        } else {
            content
                .background(
                    reduceTransparency ? AnyShapeStyle(Color(.systemBackground)) : AnyShapeStyle(.regularMaterial),
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.secondary.opacity(increasedContrast ? 0.8 : 0.35), lineWidth: increasedContrast ? 1.5 : 0.75)
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 4)
        }
    }
}

// MARK: - MiniPlayerView

/// Compact bar overlaid at the bottom of MainTabView when the player is minimized.
/// Shows a live video thumbnail (the shared PersistentPlayerHostView), title,
/// channel, play/pause button, and a close button.
/// Tapping the bar expands back to full-screen.
struct MiniPlayerView: View {
    @Environment(PlayerStateStore.self) private var playerState
    @Environment(PlayerRouter.self) private var playerRouter
    let openDetails: () -> Void
    @State private var showTranscript = false

    var body: some View {
        NowPlayingAccessoryChrome(
            title: playerRouter.audioFirst.currentVideo?.title ?? "Текущее аудио",
            isPlaying: playerState.vm.isPlaying,
            canTogglePlayback: playerState.vm.player.currentItem != nil,
            openDetails: openDetails,
            togglePlayback: {
                iPocketTubeHaptics.shared.perform(.playbackTransport)
                playerState.vm.togglePlayPause()
            },
            close: {
                iPocketTubeHaptics.shared.perform(.primaryAction)
                playerRouter.closeAudioFirst()
            },
            openTranscript: {
                iPocketTubeHaptics.shared.perform(.contentSelection)
                showTranscript = true
            }
        ) {
            ZStack {
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
            }
        }
        .fullScreenCover(isPresented: $showTranscript) {
            CurrentPlaybackTranscriptPanel {
                showTranscript = false
            }
        }
    }
}

#endif
