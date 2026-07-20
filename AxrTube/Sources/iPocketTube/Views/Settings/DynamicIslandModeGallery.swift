#if DEBUG && os(iOS)
import SwiftUI
import iPocketTubeCore

public struct DynamicIslandModeGallery: View {
    private let green = Color(red: 0.10, green: 0.78, blue: 0.28)
    private let columns = [GridItem(.flexible()), GridItem(.flexible())]

    public init() {}

    public var body: some View {
        ZStack {
            Color(red: 0.055, green: 0.06, blue: 0.075).ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("AxrTube Dynamic Island Lab")
                            .font(.title2.bold())
                            .foregroundStyle(.white)
                        Text("System-paced snapshots, never a 120 Hz visualizer")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.62))
                    }

                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(PlaybackLiveActivityMode.allCases, id: \.self) { mode in
                            modeCard(mode)
                        }
                    }

                    HStack(spacing: 10) {
                        themeSample(title: "LIGHT", background: .white, foreground: .black)
                        themeSample(title: "DARK", background: Color(white: 0.10), foreground: .white)
                    }
                }
                .padding(18)
            }
        }
        .accessibilityIdentifier("dynamicIsland.modeGallery")
    }

    private func modeCard(_ mode: PlaybackLiveActivityMode) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(mode.galleryName)
                    .font(.caption.bold())
                    .foregroundStyle(.white.opacity(0.8))
                Spacer()
                Image(systemName: mode.galleryIcon)
                    .foregroundStyle(mode == .off ? .gray : green)
            }
            island(for: mode)
            Text(mode.galleryDetail)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.58))
                .lineLimit(2)
        }
        .padding(11)
        .frame(maxWidth: .infinity, minHeight: 126, alignment: .topLeading)
        .background(Color.white.opacity(0.065), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.10)))
    }

    @ViewBuilder
    private func island(for mode: PlaybackLiveActivityMode) -> some View {
        HStack(spacing: 8) {
            if mode == .off {
                Image(systemName: "circle.slash")
                    .foregroundStyle(.gray)
                Text("No activity")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.gray)
            } else {
                Image(systemName: "play.rectangle.fill")
                    .foregroundStyle(green)
                switch mode {
                case .minimal:
                    Text("AxrTube  PLAY")
                case .progress:
                    ProgressView(value: 0.42)
                        .tint(green)
                    Text("-8:31").monospacedDigit()
                case .waveform:
                    galleryWaveform
                case .line:
                    Text("Current caption line")
                case .automatic:
                    Text("AUTO  Current caption")
                case .off:
                    EmptyView()
                }
            }
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 11)
        .frame(maxWidth: .infinity, minHeight: 42)
        .background(.black, in: Capsule())
    }

    private var galleryWaveform: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(Array([0.35, 0.8, 0.5, 1.0, 0.62, 0.9, 0.42].enumerated()), id: \.offset) { _, level in
                Capsule()
                    .fill(green)
                    .frame(width: 3, height: 20 * level)
            }
        }
        .frame(maxHeight: 24)
    }

    private func themeSample(title: String, background: Color, foreground: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "play.rectangle.fill").foregroundStyle(green)
            Text(title).font(.caption2.bold()).foregroundStyle(foreground)
            Spacer()
            Text("3:29").font(.caption2.monospacedDigit()).foregroundStyle(foreground.opacity(0.72))
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: 42)
        .background(background, in: RoundedRectangle(cornerRadius: 12))
    }
}

private extension PlaybackLiveActivityMode {
    var galleryName: String {
        switch self {
        case .off: "OFF"
        case .minimal: "MINIMAL"
        case .progress: "PROGRESS"
        case .waveform: "WAVE"
        case .line: "LINE"
        case .automatic: "AUTO"
        }
    }

    var galleryIcon: String {
        switch self {
        case .off: "circle.slash"
        case .minimal: "play.circle"
        case .progress: "gauge.with.dots.needle.33percent"
        case .waveform: "waveform"
        case .line: "captions.bubble"
        case .automatic: "wand.and.stars"
        }
    }

    var galleryDetail: String {
        switch self {
        case .off: "System Now Playing only"
        case .minimal: "Brand, state, short title"
        case .progress: "Position and remaining time"
        case .waveform: "15 second snapshot bucket"
        case .line: "Caption with safe metadata fallback"
        case .automatic: "Line, then progress, then minimal"
        }
    }
}
#endif
