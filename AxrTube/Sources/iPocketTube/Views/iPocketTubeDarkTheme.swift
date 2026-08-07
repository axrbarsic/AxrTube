import SwiftUI
import iPocketTubeCore
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

struct iPocketTubeThemeRGBA: Equatable, Sendable {
    let red: Double
    let green: Double
    let blue: Double
    let alpha: Double

    init(_ red: Double, _ green: Double, _ blue: Double, _ alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    private var relativeLuminance: Double {
        func linear(_ component: Double) -> Double {
            component <= 0.04045 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    func contrastRatio(with other: Self) -> Double {
        let brighter = max(relativeLuminance, other.relativeLuminance)
        let darker = min(relativeLuminance, other.relativeLuminance)
        return (brighter + 0.05) / (darker + 0.05)
    }
}

struct iPocketTubeThemePalette: Equatable, Sendable {
    let background: iPocketTubeThemeRGBA
    let backgroundDepth: iPocketTubeThemeRGBA
    let panel: iPocketTubeThemeRGBA
    let panelElevated: iPocketTubeThemeRGBA
    let tabBar: iPocketTubeThemeRGBA
    let primaryText: iPocketTubeThemeRGBA
    let secondaryText: iPocketTubeThemeRGBA
    let accent: iPocketTubeThemeRGBA
    let accentSoft: iPocketTubeThemeRGBA
    let accentForeground: iPocketTubeThemeRGBA
    let stroke: iPocketTubeThemeRGBA
    let success: iPocketTubeThemeRGBA
    let warning: iPocketTubeThemeRGBA
    let error: iPocketTubeThemeRGBA
    let disabled: iPocketTubeThemeRGBA

    static let dark = Self(
        background: .init(0.004, 0.020, 0.014),
        backgroundDepth: .init(0.000, 0.115, 0.058),
        panel: .init(0.010, 0.042, 0.029),
        panelElevated: .init(0.018, 0.068, 0.044),
        tabBar: .init(0.006, 0.030, 0.020),
        primaryText: .init(0.956, 0.988, 0.969),
        secondaryText: .init(0.650, 0.780, 0.690),
        accent: .init(0.310, 1.000, 0.580),
        accentSoft: .init(0.570, 0.910, 0.690),
        accentForeground: .init(0.000, 0.090, 0.040),
        stroke: .init(0.280, 0.950, 0.550, 0.32),
        success: .init(0.310, 1.000, 0.580),
        warning: .init(1.000, 0.670, 0.240),
        error: .init(1.000, 0.310, 0.300),
        disabled: .init(0.390, 0.470, 0.420)
    )

    static let light = Self(
        background: .init(0.975, 0.978, 0.985),
        backgroundDepth: .init(0.895, 0.918, 0.950),
        panel: .init(1.000, 1.000, 1.000),
        panelElevated: .init(0.945, 0.952, 0.970),
        tabBar: .init(0.975, 0.978, 0.985),
        primaryText: .init(0.055, 0.075, 0.115),
        secondaryText: .init(0.310, 0.345, 0.410),
        accent: .init(0.025, 0.430, 0.225),
        accentSoft: .init(0.055, 0.380, 0.220),
        accentForeground: .init(1.000, 1.000, 1.000),
        stroke: .init(0.045, 0.430, 0.225, 0.26),
        success: .init(0.020, 0.420, 0.215),
        warning: .init(0.650, 0.340, 0.020),
        error: .init(0.710, 0.080, 0.080),
        disabled: .init(0.560, 0.620, 0.580)
    )
}

private extension Color {
    static func iPocketTubeAdaptive(
        light: iPocketTubeThemeRGBA,
        dark: iPocketTubeThemeRGBA
    ) -> Color {
        #if canImport(UIKit)
        Color(uiColor: UIColor { traits in
            let value = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(
                red: CGFloat(value.red),
                green: CGFloat(value.green),
                blue: CGFloat(value.blue),
                alpha: CGFloat(value.alpha)
            )
        })
        #elseif canImport(AppKit)
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let value = isDark ? dark : light
            return NSColor(
                red: CGFloat(value.red),
                green: CGFloat(value.green),
                blue: CGFloat(value.blue),
                alpha: CGFloat(value.alpha)
            )
        })
        #else
        Color(red: light.red, green: light.green, blue: light.blue, opacity: light.alpha)
        #endif
    }
}

/// iPocketTube-specific visual language. These tokens intentionally stay in the
/// app target: they encode iPocketTube identity rather than reusable foundation.
enum iPocketTubeVisualTokens {
    private static func adaptive(_ keyPath: KeyPath<iPocketTubeThemePalette, iPocketTubeThemeRGBA>) -> Color {
        .iPocketTubeAdaptive(light: iPocketTubeThemePalette.light[keyPath: keyPath], dark: iPocketTubeThemePalette.dark[keyPath: keyPath])
    }

    static let background = adaptive(\.background)
    static let backgroundDepth = adaptive(\.backgroundDepth)
    static let panel = adaptive(\.panel)
    static let panelElevated = adaptive(\.panelElevated)
    static let tabBar = adaptive(\.tabBar)
    static let primaryText = adaptive(\.primaryText)
    static let mint = adaptive(\.accent)
    static let mintSoft = adaptive(\.accentSoft)
    static let accentForeground = adaptive(\.accentForeground)
    static let secondaryText = adaptive(\.secondaryText)
    static let stroke = adaptive(\.stroke)
    static let success = adaptive(\.success)
    static let error = adaptive(\.error)
    static let disabled = adaptive(\.disabled)
    static let redAccent = Color(red: 0.95, green: 0.08, blue: 0.08)
    static let warning = adaptive(\.warning)
    static let radius: CGFloat = 18
    static let horizontalPadding: CGFloat = 16
}

/// Static, inexpensive matrix-like backdrop. It never overlays videos or
/// thumbnails; screen content is composed above it.
struct iPocketTubeBackdrop: View {
    @Environment(SettingsStore.self) private var store
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    private var theme: AppSettings.ThemeName { store.settings.themeName }

    var body: some View {
        ZStack {
            iPocketTubeVisualTokens.background
            if theme == .matrix {
                LinearGradient(
                    colors: [
                        iPocketTubeVisualTokens.backgroundDepth.opacity(0.72),
                        iPocketTubeVisualTokens.background.opacity(0.42),
                        iPocketTubeVisualTokens.backgroundDepth.opacity(0.34)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            } else if theme.usesColorWash {
                LinearGradient(
                    colors: [
                        iPocketTubeVisualTokens.backgroundDepth.opacity(colorScheme == .dark ? 0.28 : 0.20),
                        iPocketTubeVisualTokens.background,
                        iPocketTubeVisualTokens.backgroundDepth.opacity(colorScheme == .dark ? 0.18 : 0.12)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
            creativeBackdrop
            if theme == .matrix && !reduceTransparency {
                RadialGradient(
                    colors: [iPocketTubeVisualTokens.mint.opacity(glowOpacity), .clear],
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
                    context.stroke(path, with: .color(iPocketTubeVisualTokens.mint.opacity(colorScheme == .dark ? 0.05 : 0.035)), lineWidth: 0.5)
                }
            }
        }
        .overlay(iPocketTubeVisualTokens.background.opacity(backdropOverlayOpacity))
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var creativeBackdrop: some View {
        switch theme {
        case .spatialDeck:
            LinearGradient(
                colors: [
                    Color(red: 0.015, green: 0.025, blue: 0.080),
                    Color(red: 0.030, green: 0.045, blue: 0.150),
                    Color(red: 0.055, green: 0.018, blue: 0.120)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            if !reduceTransparency {
                RadialGradient(
                    colors: [Color.cyan.opacity(0.22), .clear],
                    center: .topTrailing,
                    startRadius: 8,
                    endRadius: 380
                )
                RadialGradient(
                    colors: [Color.purple.opacity(0.18), .clear],
                    center: .bottomLeading,
                    startRadius: 0,
                    endRadius: 460
                )
            }

        case .livingPoster:
            LinearGradient(
                colors: [
                    Color(red: 0.035, green: 0.025, blue: 0.030),
                    Color(red: 0.120, green: 0.020, blue: 0.032),
                    Color(red: 0.025, green: 0.018, blue: 0.030)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            if !reduceTransparency {
                RadialGradient(
                    colors: [Color.orange.opacity(0.20), .clear],
                    center: .topLeading,
                    startRadius: 0,
                    endRadius: 420
                )
            }

        case .signalMap:
            Color(red: 0.965, green: 0.970, blue: 0.985)
            if !reduceTransparency {
                LinearGradient(
                    colors: [Color.blue.opacity(0.08), .clear, Color.orange.opacity(0.07)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Canvas { context, size in
                    var path = Path()
                    stride(from: -size.height, through: size.width, by: 74).forEach { offset in
                        path.move(to: CGPoint(x: offset, y: 0))
                        path.addLine(to: CGPoint(x: offset + size.height, y: size.height))
                    }
                    context.stroke(path, with: .color(Color.blue.opacity(0.035)), lineWidth: 1)
                }
            }

        case .prismRooms:
            LinearGradient(
                colors: [
                    Color(red: 0.018, green: 0.020, blue: 0.090),
                    Color(red: 0.090, green: 0.018, blue: 0.160),
                    Color(red: 0.015, green: 0.085, blue: 0.120)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            if !reduceTransparency {
                AngularGradient(
                    colors: [
                        Color.cyan.opacity(0.10),
                        Color.pink.opacity(0.13),
                        Color.purple.opacity(0.15),
                        Color.cyan.opacity(0.10)
                    ],
                    center: .center
                )
                .blur(radius: 42)
            }

        default:
            EmptyView()
        }
    }

    private var backdropOverlayOpacity: Double {
        switch theme {
        case .matrix:
            return 0.14
        case .monochrome, .timeline:
            return 0.02
        case .colorWashDark:
            return 0.12
        case .colorWashLight:
            return 0.04
        case .spatialDeck, .livingPoster, .prismRooms:
            return 0.05
        case .signalMap:
            return 0.015
        }
    }

    private var glowOpacity: Double {
        let restrained = reduceMotion || ProcessInfo.processInfo.isLowPowerModeEnabled
        if colorScheme == .dark { return restrained ? 0.07 : 0.12 }
        return restrained ? 0.025 : 0.045
    }
}

private struct iPocketTubeScreenSurfaceModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background { iPocketTubeBackdrop().ignoresSafeArea() }
            .tint(iPocketTubeVisualTokens.mint)
    }
}

private struct iPocketTubeCardSurfaceModifier: ViewModifier {
    let cornerRadius: CGFloat
    let contentPadding: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        content
            .padding(contentPadding)
            .background(
                reduceTransparency ? AnyShapeStyle(iPocketTubeVisualTokens.panel) : AnyShapeStyle(.thinMaterial),
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(iPocketTubeVisualTokens.stroke, lineWidth: 0.8)
            }
            .shadow(color: iPocketTubeVisualTokens.mint.opacity(0.07), radius: 12)
    }
}

/// Solid semantic playback surface. Unlike the general thin-material cards it
/// does not pick up a grey system cast, so the active card and its transparent
/// scope remain in the same light or Matrix palette as the page.
private struct iPocketTubeActivePlaybackSurfaceModifier: ViewModifier {
    let cornerRadius: CGFloat
    let contentPadding: CGFloat

    func body(content: Content) -> some View {
        content
            .padding(contentPadding)
            .background(
                iPocketTubeVisualTokens.panel,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(iPocketTubeVisualTokens.stroke, lineWidth: 0.8)
            }
    }
}

/// Applies Apple's Liquid Glass only to app chrome and custom controls. Content
/// cards deliberately use the calmer semantic material surface above.
private struct iPocketTubeGlassSurfaceModifier: ViewModifier {
    let cornerRadius: CGFloat
    let interactive: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 26.0, macOS 26.0, tvOS 26.0, *) {
            if reduceTransparency {
                content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            } else {
                content.glassEffect(interactive ? .regular.interactive() : .regular, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            }
        } else {
            content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }
}

private struct iPocketTubeLiquidButtonStyleModifier: ViewModifier {
    let prominent: Bool

    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 26.0, macOS 26.0, tvOS 26.0, *) {
            if prominent {
                content.buttonStyle(.glassProminent)
            } else {
                content.buttonStyle(.glass)
            }
        } else {
            if prominent {
                content.buttonStyle(.borderedProminent)
            } else {
                content.buttonStyle(.bordered)
            }
        }
    }
}

struct iPocketTubeMatrixHeader: View {
    let title: LocalizedStringKey
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title, bundle: .module)
                .font(.system(.largeTitle, design: .rounded, weight: .heavy))
                .foregroundStyle(iPocketTubeVisualTokens.primaryText)
            if let subtitle {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(iPocketTubeVisualTokens.secondaryText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, iPocketTubeVisualTokens.horizontalPadding)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }
}

struct iPocketTubeMatrixSection<Content: View>: View {
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
                    .foregroundStyle(iPocketTubeVisualTokens.primaryText)
            } icon: {
                Image(systemName: systemImage)
                    .foregroundStyle(iPocketTubeVisualTokens.mint)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .iPocketTubeCardSurface(cornerRadius: iPocketTubeVisualTokens.radius, contentPadding: 16)
    }
}

extension View {
    func iPocketTubeScreenSurface() -> some View {
        modifier(iPocketTubeScreenSurfaceModifier())
    }

    func iPocketTubeCardSurface(cornerRadius: CGFloat = 14, contentPadding: CGFloat = 6) -> some View {
        modifier(iPocketTubeCardSurfaceModifier(cornerRadius: cornerRadius, contentPadding: contentPadding))
    }

    func iPocketTubeActivePlaybackSurface(cornerRadius: CGFloat = 18, contentPadding: CGFloat = 14) -> some View {
        modifier(iPocketTubeActivePlaybackSurfaceModifier(
            cornerRadius: cornerRadius,
            contentPadding: contentPadding
        ))
    }

    func iPocketTubeGlassSurface(cornerRadius: CGFloat = 18, interactive: Bool = false) -> some View {
        modifier(iPocketTubeGlassSurfaceModifier(cornerRadius: cornerRadius, interactive: interactive))
    }

    func iPocketTubeLiquidButtonStyle(prominent: Bool = false) -> some View {
        modifier(iPocketTubeLiquidButtonStyleModifier(prominent: prominent))
    }

    @ViewBuilder
    func iPocketTubeLiquidTabChrome<Accessory: View>(
        isAccessoryPresented: Bool,
        @ViewBuilder accessory: () -> Accessory
    ) -> some View {
        #if os(iOS)
        if #available(iOS 26.1, *) {
            self
                .tabBarMinimizeBehavior(.never)
                .tabViewBottomAccessory(isEnabled: isAccessoryPresented) {
                    accessory()
                }
        } else if #available(iOS 26.0, *), isAccessoryPresented {
            self
                .tabBarMinimizeBehavior(.never)
                .tabViewBottomAccessory { accessory() }
        } else {
            self
        }
        #else
        self
        #endif
    }
}
