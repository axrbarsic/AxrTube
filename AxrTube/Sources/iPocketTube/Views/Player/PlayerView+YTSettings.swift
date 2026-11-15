#if os(iOS)
import SwiftUI
import iPocketTubeCore

// MARK: - YouTube player settings sheet (gear)
//
// Quality, captions, speed, sleep timer, audio track, audio-only and stats,
// in YouTube's bottom-sheet list. Each row hands over to the existing picker.
extension PlayerView {

    var ytSettingsSheet: some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(0.4)
                .ignoresSafeArea()
                .onTapGesture { showMoreMenu = false }
            VStack(spacing: 0) {
                Capsule().fill(YTColor.divider).frame(width: 36, height: 4).padding(.vertical, 8)
                settingsRow("slider.horizontal.3", "Качество", value: qualityValue) { open { showQualityPicker = true } }
                if !vm.availableCaptions.isEmpty {
                    settingsRow("captions.bubble", "Субтитры", value: vm.selectedCaption?.name ?? "Выкл.") { open { showCaptionPicker = true } }
                }
                settingsRow("speedometer", "Скорость воспроизведения", value: speedValue) { open { showSpeedPicker = true } }
                settingsRow("moon.zzz", "Таймер сна", value: vm.sleepTimerMinutes.map { "\($0) мин" } ?? "Выкл.") {
                    open { showSleepTimerPicker = true }
                }
                if shouldShowAudioTrackInMoreMenu {
                    settingsRow("waveform", "Звуковая дорожка", value: vm.selectedAudioTrack?.name ?? "Авто") {
                        open { showAudioTrackPicker = true }
                    }
                }
                audioOnlyRow
                settingsRow("text.quote", "Текст видео", value: nil) { open { showTranscript = true } }
                settingsRow("chart.bar.xaxis", "Статистика для сисадминов", value: vm.statsForNerdsVisible ? "Вкл." : nil) {
                    showMoreMenu = false
                    vm.toggleStatsForNerds()
                }
            }
            .padding(.bottom, 20)
            .frame(maxWidth: 600)
            .background(YTColor.elevated, in: UnevenRoundedRectangle(topLeadingRadius: 16, topTrailingRadius: 16))
            .foregroundStyle(YTColor.primaryText)
        }
        .ignoresSafeArea(edges: .bottom)
        .accessibilityIdentifier("player.moreMenu")
    }

    private var audioOnlyRow: some View {
        @Bindable var store = store
        return Toggle(isOn: $store.settings.audioOnlyMode) {
            Label("Только аудио", systemImage: "headphones")
                .font(.system(size: 15))
        }
        .padding(.horizontal, 18)
        .frame(height: 50)
    }

    private var qualityValue: String {
        vm.selectedFormat?.qualityLabel ?? (vm.pendingQualityLabel.isEmpty ? "Авто" : vm.pendingQualityLabel)
    }

    private var speedValue: String {
        store.settings.playbackSpeed == 1 ? "Обычная" : "\(store.settings.playbackSpeed.formatted())×"
    }

    private func open(_ action: () -> Void) {
        iPocketTubeHaptics.shared.perform(.primaryAction)
        showMoreMenu = false
        action()
    }

    private func settingsRow(_ icon: String, _ title: String, value: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 18) {
                Image(systemName: icon).font(.system(size: 18)).frame(width: 24)
                Text(title).font(.system(size: 15))
                Spacer()
                if let value {
                    Text(value).font(.system(size: 14)).foregroundStyle(YTColor.secondaryText)
                }
                Image(systemName: "chevron.right").font(.system(size: 12)).foregroundStyle(YTColor.secondaryText)
            }
            .padding(.horizontal, 18)
            .frame(height: 50)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
#endif
