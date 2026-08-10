#if os(iOS)
import AVFoundation

enum DirectAudioPlaybackAssetFactory {
    static func make(
        url: URL,
        userAgent: String,
        allowsCellularAccess: Bool = true
    ) -> AVURLAsset {
        AVURLAsset(
            url: url,
            options: [
                AVURLAssetHTTPUserAgentKey: userAgent,
                AVURLAssetAllowsCellularAccessKey: allowsCellularAccess,
                AVURLAssetAllowsExpensiveNetworkAccessKey: true,
                AVURLAssetAllowsConstrainedNetworkAccessKey: true,
            ]
        )
    }
}
#endif
