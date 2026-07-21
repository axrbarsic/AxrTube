#if DEBUG && os(iOS)
import SwiftUI
import iPocketTubeCore

public struct DynamicIslandModeGallery: View {
    private let green = Color(red: 0.10, green: 0.78, blue: 0.28)
    private let yellow = Color(red: 1.0, green: 0.78, blue: 0.12)
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
                        progressCard
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

    private var progressCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("PROGRESS")
                    .font(.caption.bold())
                    .foregroundStyle(.white.opacity(0.8))
                Spacer()
                Image(systemName: "chart.bar.fill")
                    .foregroundStyle(green)
            }
            island
            Text("Green played, yellow remaining")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.58))
                .lineLimit(2)
        }
        .padding(11)
        .frame(maxWidth: .infinity, minHeight: 126, alignment: .topLeading)
        .background(Color.white.opacity(0.065), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.10)))
    }

    private var island: some View {
        HStack(spacing: 8) {
            Image(systemName: "play.rectangle.fill")
                .foregroundStyle(green)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(yellow)
                    Capsule()
                        .fill(green)
                        .frame(width: proxy.size.width * 0.42)
                }
            }
            .frame(height: 6)
            Text("-8:31").monospacedDigit()
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 11)
        .frame(maxWidth: .infinity, minHeight: 42)
        .background(.black, in: Capsule())
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
#endif
