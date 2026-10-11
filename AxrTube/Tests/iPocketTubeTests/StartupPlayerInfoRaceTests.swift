import Foundation
import Testing
@testable import iPocketTubeCore

@Suite("Startup player info race")
struct StartupPlayerInfoRaceTests {
    struct Failure: Error {}

    private static func info(hls: Bool, tag: String) -> PlayerInfo {
        PlayerInfo(
            video: Video(id: "v", title: tag, channelTitle: "c"),
            formats: [],
            hlsURL: hls ? URL(string: "https://manifest.googlevideo.com/\(tag)") : nil,
            dashURL: nil,
            captionTracks: [],
            trackingURLs: nil,
            endCards: []
        )
    }

    @Test func secondaryHLSWinsWhenPrimaryHasNone() async throws {
        let result = try await StartupPlayerInfoRace.firstPlayable(
            primary: { Self.info(hls: false, tag: "ios") },
            secondary: { Self.info(hls: true, tag: "vision") }
        )
        #expect(result.video.title == "vision")
    }

    @Test func fastHLSDoesNotWaitForSlowClient() async throws {
        let clock = ContinuousClock()
        let start = clock.now
        let result = try await StartupPlayerInfoRace.firstPlayable(
            primary: {
                try await Task.sleep(for: .seconds(5))
                return Self.info(hls: true, tag: "slow")
            },
            secondary: { Self.info(hls: true, tag: "fast") }
        )
        #expect(result.video.title == "fast")
        #expect(clock.now - start < .seconds(2))
    }

    @Test func primaryIsKeptWhenNoClientHasHLS() async throws {
        let result = try await StartupPlayerInfoRace.firstPlayable(
            primary: { Self.info(hls: false, tag: "ios") },
            secondary: { Self.info(hls: false, tag: "vision") }
        )
        #expect(result.video.title == "ios")
    }

    @Test func secondaryResultSurvivesPrimaryFailure() async throws {
        let result = try await StartupPlayerInfoRace.firstPlayable(
            primary: { throw Failure() },
            secondary: { Self.info(hls: false, tag: "vision") }
        )
        #expect(result.video.title == "vision")
    }

    @Test func primaryErrorIsThrownWhenBothFail() async {
        await #expect(throws: Failure.self) {
            _ = try await StartupPlayerInfoRace.firstPlayable(
                primary: { throw Failure() },
                secondary: { throw CancellationError() }
            )
        }
    }
}
