import Foundation

/// Resolver pages are metadata sources, never user-facing playback fallbacks.
public enum AdFreePlaybackPolicy {
    public static func acceptsManifest(url: URL, source: String, requestedVideoID: String?,
                                       pageVideoID: String?, contentVideoID: String?) -> Bool {
        guard let requestedVideoID, !requestedVideoID.isEmpty,
              pageVideoID == requestedVideoID, contentVideoID == requestedVideoID,
              source == "apiResponse", url.scheme == "https",
              let host = url.host?.lowercased() else { return false }
        return host == "googlevideo.com" || host.hasSuffix(".googlevideo.com")
    }
}
