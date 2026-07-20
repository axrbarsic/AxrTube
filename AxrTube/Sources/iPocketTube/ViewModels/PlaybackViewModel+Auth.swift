import Foundation
import os
import iPocketTubeCore

private let playerLog = CrashlyticsLogger(category: "Player")

// MARK: - Auth Token

extension PlaybackViewModel {

    /// Updates the local auth flag used for LOGIN_REQUIRED retry logic.
    /// The shared InnerTubeAPI instance already carries the updated token.
    public func updateAuthToken(_ token: String?) {
        guard authSnapshotGeneration == nil else { return }
        let wasAuthenticated = hasAuthToken
        hasAuthToken = token != nil
        currentAuthToken = token
        // Propagate the token to the PlaybackViewModel's own API instance so that
        // WatchtimeTracker sends authenticated watch-time pings (fixes watch history
        // not being recorded for signed-in users — GitHub issue #51).
        Task { await api.setAuthToken(token) }
        // Keep the cache's InnerTubeAPI instance in sync so prefetch requests
        // can make authenticated calls (e.g. fetchAuthenticatedTrackingURLs).
        Task { await VideoPreloadCache.shared.setAuthToken(token) }
        if wasAuthenticated, token == nil {
            // Signed out: evict account-bound cache data
            Task { await VideoPreloadCache.shared.evictAuthSensitiveData() }
        } else if wasAuthenticated, token != nil {
            // Token refreshed: tracking URLs bound to the old token are stale.
            // BUG-016 fix: also clear WatchtimeTracker so any in-flight checkpoint between
            // the token refresh and the next video load uses nil URLs rather than stale ones.
            tracker.setTrackingURLs(nil)
            Task { await VideoPreloadCache.shared.evictTrackingURLs() }
        }
    }

    /// Propagates the YouTube.com SAPISID cookie to the PlaybackViewModel's own
    /// InnerTubeAPI instance so WEB_CREATOR requests use SAPISIDHASH auth.
    public func updateSAPISID(_ sapisid: String?) {
        guard authSnapshotGeneration == nil else { return }
        Task { await api.setSAPISID(sapisid) }
        Task { await VideoPreloadCache.shared.setSAPISID(sapisid) }
    }

    public func applyAuthSnapshot(_ snapshot: AuthSessionSnapshot) {
        if let current = authSnapshotGeneration, snapshot.generation <= current { return }
        let wasAuthenticated = hasAuthToken
        authSnapshotGeneration = snapshot.generation
        hasAuthToken = snapshot.accessToken != nil
        currentAuthToken = snapshot.accessToken

        if snapshot.accessToken == nil {
            // The tracker is synchronous and long-lived. Clear it before any
            // asynchronous propagation so an old Phase 2 callback cannot ping
            // account-bound URLs across the sign-out boundary.
            tracker.setTrackingURLs(nil)
        }

        authPropagationTask?.cancel()
        authPropagationTask = Task {
            await api.applyAuthSnapshot(snapshot)
            await VideoPreloadCache.shared.applyAuthSnapshot(snapshot)
            guard !Task.isCancelled else { return }
            if wasAuthenticated, snapshot.accessToken == nil {
                await VideoPreloadCache.shared.evictAuthSensitiveData()
            } else if wasAuthenticated, snapshot.accessToken != nil {
                await VideoPreloadCache.shared.evictTrackingURLs()
            }
        }
        if wasAuthenticated, snapshot.accessToken != nil {
            tracker.setTrackingURLs(nil)
        }
    }
}
