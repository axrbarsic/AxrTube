import Foundation

/// Runs two player clients concurrently and returns the first response that
/// AVPlayer can start immediately (an HLS manifest).
///
/// The iOS client often omits `hlsManifestUrl`, which used to push the tap onto
/// the long sequential fallback chain. Racing a second client keeps the first
/// frame on the fast path without waiting for the slower response.
public enum StartupPlayerInfoRace {
    private enum Slot: Sendable { case primary, secondary }

    public static func firstPlayable(
        primary: @escaping @Sendable () async throws -> PlayerInfo,
        secondary: @escaping @Sendable () async throws -> PlayerInfo
    ) async throws -> PlayerInfo {
        try await withThrowingTaskGroup(of: (Slot, Result<PlayerInfo, Error>).self) { group in
            group.addTask { (.primary, await Result { try await primary() }) }
            group.addTask { (.secondary, await Result { try await secondary() }) }

            var primaryResult: Result<PlayerInfo, Error>?
            var secondaryResult: Result<PlayerInfo, Error>?
            for try await (slot, result) in group {
                if case .success(let info) = result, info.hlsURL != nil {
                    group.cancelAll()
                    return info
                }
                switch slot {
                case .primary: primaryResult = result
                case .secondary: secondaryResult = result
                }
            }
            // No client produced HLS: keep the primary response so the existing
            // fallback chain sees the same data as before.
            if case .success(let info) = primaryResult { return info }
            if case .success(let info) = secondaryResult { return info }
            if case .failure(let error) = primaryResult { throw error }
            if case .failure(let error) = secondaryResult { throw error }
            throw CancellationError()
        }
    }
}

private extension Result where Failure == Error {
    init(catching body: () async throws -> Success) async {
        do { self = .success(try await body()) } catch { self = .failure(error) }
    }
}

extension InnerTubeAPI {
    /// Player info for the first frame: iOS and visionOS race, first HLS wins.
    public func fetchStartupPlayerInfo(videoId: String) async throws -> PlayerInfo {
        try await StartupPlayerInfoRace.firstPlayable(
            primary: { try await self.fetchPlayerInfo(videoId: videoId) },
            secondary: { try await self.fetchPlayerInfoVisionOS(videoId: videoId) }
        )
    }
}
