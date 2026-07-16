#if !os(tvOS)
import Foundation
import iPocketTubeCore

// MARK: - Auth Token
//
// Mirrors PlaybackViewModel+Auth.swift exactly. TOSPlayerViewModel owns its own
// InnerTubeAPI instance (TOSPlayerViewModel.swift:132), just like PlaybackViewModel
// does — without this propagation, WatchtimeTracker's pings carry no auth header
// even for signed-in users, so playback through the TOS player (the iOS default
// since 4.6) never registers in YouTube's watch history. Same root cause as
// GitHub issue #51, just never ported to the TOS pipeline (GitHub issue #78).

extension TOSPlayerViewModel {

    /// Propagates the auth token to this view model's own API instance so
    /// WatchtimeTracker sends authenticated watch-time pings.
    public func updateAuthToken(_ token: String?) {
        Task { await api.setAuthToken(token) }
        Task { await VideoPreloadCache.shared.setAuthToken(token) }
        // Any tracking URLs already fetched (or in-flight) may be stale/anonymous —
        // mirrors PlaybackViewModel+Auth.swift's BUG-016 fix.
        tracker.setTrackingURLs(nil)
    }

    /// Propagates the YouTube.com SAPISID cookie so WEB_CREATOR requests use
    /// SAPISIDHASH auth.
    public func updateSAPISID(_ sapisid: String?) {
        Task { await api.setSAPISID(sapisid) }
        Task { await VideoPreloadCache.shared.setSAPISID(sapisid) }
    }
}
#endif // !os(tvOS)
