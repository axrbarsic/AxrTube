import SwiftUI

/// SmartTube-specific visual language. These tokens intentionally stay in the
/// app target: they encode SmartTube identity rather than reusable foundation.
enum SmartTubeVisualTokens {
    static let background = Color(red: 0.004, green: 0.020, blue: 0.014)
    static let backgroundDepth = Color(red: 0.0, green: 0.115, blue: 0.058)
    static let panel = Color(red: 0.010, green: 0.042, blue: 0.029)
    static let panelElevated = Color(red: 0.018, green: 0.068, blue: 0.044)
    static let tabBar = Color(red: 0.006, green: 0.030, blue: 0.020)
    static let mint = Color(red: 0.31, green: 1.0, blue: 0.58)
    static let mintSoft = Color(red: 0.57, green: 0.91, blue: 0.69)
    static let secondaryText = Color(red: 0.65, green: 0.78, blue: 0.69)
    static let stroke = Color(red: 0.28, green: 0.95, blue: 0.55).opacity(0.32)
    static let redAccent = Color(red: 0.95, green: 0.08, blue: 0.08)
    static let warning = Color(red: 1.0, green: 0.67, blue: 0.24)
    static let radius: CGFloat = 18
    static let horizontalPadding: CGFloat = 16
}

/// Static, inexpensive matrix-like backdrop. It never overlays videos or
/// thumbnails; screen content is composed above it.
struct SmartTubeDarkBackdrop: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            SmartTubeVisualTokens.background
            LinearGradient(
                colors: [
                    SmartTubeVisualTokens.backgroundDepth.opacity(0.72),
                    SmartTubeVisualTokens.background.opacity(0.42),
                    SmartTubeVisualTokens.backgroundDepth.opacity(0.34)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            if !reduceTransparency {
                RadialGradient(
                    colors: [SmartTubeVisualTokens.mint.opacity(reduceMotion || ProcessInfo.processInfo.isLowPowerModeEnabled ? 0.07 : 0.12), .clear],
                    center: .topLeading,
                    startRadius: 0,
                    endRadius: 430
                )
                Canvas { context, size in
                    var path = Path()
                    stride(from: 8.0, through: size.height, by: 23.0).forEach { y in
                        path.move(to: CGPoint(x: 0, y: y))
                        path.addLine(to: CGPoint(x: size.width, y: y))
                    }
                    stride(from: 16.0, through: size.width, by: 64.0).forEach { x in
                        path.move(to: CGPoint(x: x, y: 0))
                        path.addLine(to: CGPoint(x: x, y: size.height))
                    }
                    context.stroke(path, with: .color(SmartTubeVisualTokens.mint.opacity(0.05)), lineWidth: 0.5)
                }
            }
        }
        .overlay(SmartTubeVisualTokens.background.opacity(0.18))
        .accessibilityHidden(true)
    }
}

private struct SmartTubeScreenSurfaceModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background { SmartTubeDarkBackdrop().ignoresSafeArea() }
            .tint(SmartTubeVisualTokens.mint)
    }
}

private struct SmartTubeCardSurfaceModifier: ViewModifier {
    let cornerRadius: CGFloat
    let contentPadding: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        content
            .padding(contentPadding)
            .background(
                (reduceTransparency ? SmartTubeVisualTokens.panel : SmartTubeVisualTokens.panel.opacity(0.91)),
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(SmartTubeVisualTokens.stroke, lineWidth: 0.8)
            }
            .shadow(color: SmartTubeVisualTokens.mint.opacity(0.07), radius: 12)
    }
}

struct SmartTubeMatrixHeader: View {
    let title: LocalizedStringKey
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title, bundle: .module)
                .font(.system(.largeTitle, design: .rounded, weight: .heavy))
                .foregroundStyle(.white)
            if let subtitle {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(SmartTubeVisualTokens.secondaryText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, SmartTubeVisualTokens.horizontalPadding)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }
}

struct SmartTubeMatrixSection<Content: View>: View {
    let title: LocalizedStringKey
    let systemImage: String
    @ViewBuilder let content: Content

    init(
        _ title: LocalizedStringKey,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.systemImage = systemImage
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label {
                Text(title, bundle: .module)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.white)
            } icon: {
                Image(systemName: systemImage)
                    .foregroundStyle(SmartTubeVisualTokens.mint)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .smartTubeCardSurface(cornerRadius: SmartTubeVisualTokens.radius, contentPadding: 16)
    }
}

extension View {
    func smartTubeScreenSurface() -> some View {
        modifier(SmartTubeScreenSurfaceModifier())
    }

    func smartTubeCardSurface(cornerRadius: CGFloat = 14, contentPadding: CGFloat = 6) -> some View {
        modifier(SmartTubeCardSurfaceModifier(cornerRadius: cornerRadius, contentPadding: contentPadding))
    }
}
