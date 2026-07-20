import SwiftUI
import iPocketTubeCore

#if os(iOS)
import UIKit
import QuartzCore

private struct iPocketTubePressPulseEvent: Identifiable {
    let id = UUID()
    let startedAt: Date
}

private struct iPocketTubeEDRPressModifier: ViewModifier {
    let enabled: Bool
    let cornerRadius: CGFloat

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var events: [iPocketTubePressPulseEvent] = []
    @State private var gestureActive = false
    @State private var lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled

    func body(content: Content) -> some View {
        content
            .background {
                if enabled, colorScheme == .dark {
                    TimelineView(.animation(minimumInterval: 1.0 / 120.0, paused: events.isEmpty)) { timeline in
                        let heat = events
                            .map { iPocketTubePressPulseEnvelope.heat(
                                elapsed: timeline.date.timeIntervalSince($0.startedAt),
                                reduceMotion: reduceMotion
                            ) }
                            .max() ?? 0
                        if permitsHardwareEDR {
                            iPocketTubeEDRPulseLayer(
                                heat: heat,
                                cornerRadius: cornerRadius,
                                permitsEDR: true
                            )
                        } else {
                            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                                .fill(iPocketTubeVisualTokens.mint.opacity(0.055 * heat))
                                .overlay {
                                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                                        .stroke(iPocketTubeVisualTokens.mint.opacity(0.30 * heat), lineWidth: 1.5)
                                }
                        }
                    }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard enabled, colorScheme == .dark, !gestureActive else { return }
                        gestureActive = true
                        triggerPulse()
                    }
                    .onEnded { _ in gestureActive = false }
            )
            .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in
                lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
            }
    }

    private var permitsHardwareEDR: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        return !lowPowerMode && UIScreen.main.potentialEDRHeadroom > 1.01
        #endif
    }

    private func triggerPulse() {
        let event = iPocketTubePressPulseEvent(startedAt: Date())
        events.append(event)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(900))
            events.removeAll { $0.id == event.id }
        }
    }
}

private struct iPocketTubeEDRPulseLayer: UIViewRepresentable {
    let heat: Double
    let cornerRadius: CGFloat
    let permitsEDR: Bool

    func makeUIView(context: Context) -> iPocketTubeEDRPulseView {
        iPocketTubeEDRPulseView()
    }

    func updateUIView(_ view: iPocketTubeEDRPulseView, context: Context) {
        view.heat = CGFloat(heat)
        view.cornerRadius = cornerRadius
        view.permitsEDR = permitsEDR
    }
}

private final class iPocketTubeEDRPulseView: UIView {
    var heat: CGFloat = 0 { didSet { setNeedsDisplay() } }
    var cornerRadius: CGFloat = 14 { didSet { setNeedsDisplay() } }
    var permitsEDR = true { didSet { configureDynamicRange(); setNeedsDisplay() } }

    private static let extendedP3 = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
        ?? CGColorSpaceCreateDeviceRGB()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        isUserInteractionEnabled = false
        backgroundColor = .clear
        contentMode = .redraw
        layer.contentsScale = UIScreen.main.scale
        layer.contentsFormat = .RGBA16Float
        layer.drawsAsynchronously = true
        configureDynamicRange()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func draw(_ rect: CGRect) {
        guard heat > 0, !bounds.isEmpty, let context = UIGraphicsGetCurrentContext() else { return }
        configureDynamicRange()
        context.clear(rect)

        let targetHeadroom = effectiveHeadroom
        if #available(iOS 18.0, *), targetHeadroom > 1.01 {
            _ = context.setEDRTargetHeadroom(Float(targetHeadroom))
        }

        let path = UIBezierPath(
            roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5),
            cornerRadius: max(1, cornerRadius - 1.5)
        )
        context.saveGState()
        path.addClip()
        context.setBlendMode(.plusLighter)
        context.setAlpha(heat)
        context.setStrokeColor(pulseColor(headroom: targetHeadroom, alpha: 0.92))
        context.setLineWidth(3)
        context.addPath(path.cgPath)
        context.strokePath()

        if let gradient = CGGradient(
            colorsSpace: Self.extendedP3,
            colors: [
                pulseColor(headroom: targetHeadroom, alpha: 0.34),
                pulseColor(headroom: targetHeadroom, alpha: 0.08),
                pulseColor(headroom: targetHeadroom, alpha: 0)
            ] as CFArray,
            locations: [0, 0.45, 1]
        ) {
            let center = CGPoint(x: bounds.midX, y: bounds.midY)
            context.drawRadialGradient(
                gradient,
                startCenter: center,
                startRadius: 0,
                endCenter: center,
                endRadius: max(bounds.width, bounds.height) * 0.72,
                options: [.drawsAfterEndLocation]
            )
        }
        context.restoreGState()
    }

    private var effectiveHeadroom: CGFloat {
        guard permitsEDR else { return 1 }
        let screen = UIScreen.main
        let potential = max(screen.potentialEDRHeadroom, 1)
        let current = max(screen.currentEDRHeadroom, 1)
        guard potential > 1.01 else { return 1 }
        return min(max(current, potential * 0.82), min(potential, 4.0))
    }

    private func configureDynamicRange() {
        let headroom = effectiveHeadroom
        if #available(iOS 26.0, *) {
            layer.preferredDynamicRange = headroom > 1.01 ? .high : .standard
            layer.contentsHeadroom = headroom
        } else if #available(iOS 17.0, *) {
            layer.wantsExtendedDynamicRangeContent = headroom > 1.01
        }
    }

    private func pulseColor(headroom: CGFloat, alpha: CGFloat) -> CGColor {
        let lift = max(headroom, 1)
        return CGColor(
            colorSpace: Self.extendedP3,
            components: [0.19 * lift, 1.0 * lift, 0.43 * lift, alpha]
        ) ?? UIColor.systemGreen.withAlphaComponent(alpha).cgColor
    }
}
#endif

extension View {
    @ViewBuilder
    func iPocketTubeEDRPressEffect(enabled: Bool, cornerRadius: CGFloat = 14) -> some View {
        #if os(iOS)
        modifier(iPocketTubeEDRPressModifier(enabled: enabled, cornerRadius: cornerRadius))
        #else
        self
        #endif
    }
}
