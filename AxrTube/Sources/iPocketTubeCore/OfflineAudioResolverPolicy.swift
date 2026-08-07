import Foundation

/// Stable resolver identities for offline audio. Keeping the identity separate
/// from its User-Agent lets a stale signed URL be refreshed by the same client.
package enum OfflineAudioResolverClient: String, CaseIterable, Sendable {
    case visionOS = "visionos"
    case androidVR = "android-vr"
    case android = "android"

    package static let preferredOrder: [Self] = [.visionOS, .androidVR, .android]

    package var userAgent: String {
        switch self {
        case .visionOS: InnerTubeClients.VisionOS.userAgent
        case .androidVR: InnerTubeClients.AndroidVR.userAgent
        case .android: InnerTubeClients.Android.userAgent
        }
    }
}
