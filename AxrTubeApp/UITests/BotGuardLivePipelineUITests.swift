import XCTest

// AGENT-POST-RUN-CHECK: ui-tests-with-logs
//
// After running this test, export device logs and search for the BotGuard
// pipeline phase markers emitted by BotGuardClient and AppEntry.
//
// ─── Phase 1 SUCCESS (WAA Create descrambled, BgUtils v3.2) ──────────────────
//   "[BotGuardProbe] 🔵 starting probe for videoId=..."
//   "[BotGuard] WAA Create raw response (first 300): ..."
//   "[BotGuard] outer[1] is String len=... — descrambling (BgUtils v3.2 format)"
//   "[BotGuard] descrambled JSON (first 200): ..."
//   "[BotGuard] inner parse: globalName='...' programLen=..."
//   "[BotGuard] challenge ok, globalName='...' jsLen=..."
//
// ─── Phase 1 FALLBACK (descramble failed → YouTube homepage) ─────────────────
//   "[BotGuard] descramble failed: ..."
//   "[BotGuard] all parse strategies failed — fetching interpreter from YouTube homepage"
//
// ─── Phase 2 SUCCESS (VM executed, asyncSnapshotFn set) ──────────────────────
//   "[BotGuard] Phase 2 ✅ VM loaded, asyncSnapshotFn set"
//
// ─── Phase 3 SUCCESS (botguardResponse non-empty) ────────────────────────────
//   "[BotGuard] Phase 3 ✅ botguardResponse len=..."
//
// ─── Phase 4 SUCCESS (integrity token obtained) ──────────────────────────────
//   "[BotGuard] integrity token obtained (len=...)"
//
// ─── Phase 5 / Full pipeline SUCCESS ─────────────────────────────────────────
//   "[BotGuard] ✅ PO token minted (len=...) for ..."
//   "[BotGuardProbe] ✅ PIPELINE COMPLETE tokenLen=... videoId=..."
//
// ─── Full pipeline FAILURE ────────────────────────────────────────────────────
//   "[BotGuardProbe] ❌ PIPELINE FAILED error=... videoId=..."
//
// ─── Diagnose phase failures ─────────────────────────────────────────────────
//   Phase 1 ❌: descramble failed + all parse strategies failed
//   Phase 2 ❌: "asyncSnapshotFn not set after vm.a()" or "vm.a():" JS error
//   Phase 3 ❌: "botguard response empty after asyncSnapshotFn"
//   Phase 4 ❌: "integrityTokenFailed" HTTP status
//   Phase 5 ❌: "mintFailed" message

final class BotGuardLivePipelineUITests: XCTestCase {

    private static let videoID = "LSMQ3U1Thzw"

    func testLivePipelineDoesNotCrashApp() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "--uitesting",
            "--uitesting-botguard-probe=\(Self.videoID)"
        ]
        app.launch()

        // Allow up to 60 s for the pipeline to complete network + JS execution.
        // Real-device timing: Phase 1 ~3 s, Phase 2 ~15 s (JS execution),
        // Phase 3-4 ~3 s, Phase 5 < 1 s.
        Thread.sleep(forTimeInterval: 60)

        XCTAssertEqual(app.state, .runningForeground,
                       "App crashed during BotGuard live pipeline probe")
    }
}
