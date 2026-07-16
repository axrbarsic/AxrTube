# TOS Player for Shorts (iOS) — Design

## Context

The TOS player (YouTube's official IFrame/embed player rendered in a `WKWebView`, with native SwiftUI controls overlaid) became the iOS default for regular videos in v4.5. It eliminates an entire class of failures inherent to the AVPlayer-based stream-extraction pipeline: BotGuard/PO-token requirements, CDN/geo-block issues, multi-client fallback chains, and HLS/DASH manifest parsing.

Shorts on iOS still use a separate, AVPlayer-based pipeline (`ShortsPlayerView` + `PlaybackViewModel`), entirely bypassing `PlayerRouter`'s TOS-vs-AVPlayer decision. This means Shorts remain exposed to the same failure classes that TOS eliminated for regular videos.

## Goal

Replace the AVPlayer-based Shorts pipeline with a TOS/embed-based pipeline, for the same robustness reasons the regular-video switch was made, while preserving the existing Shorts UX (vertical swipe paging, gestures, overlays).

## Decisions

| Question | Decision |
|---|---|
| Motivation | Robustness/compliance parity with regular videos is the primary driver; one-pipeline consistency is a secondary benefit. |
| Swipe-latency strategy | Start with a single persistent `WKWebView` per Shorts session, swapping the embedded `<iframe>`'s `src` on each swipe. Measure real-world latency; only build a multi-WKWebView preload pool later if this proves too slow. |
| Replacement scope | **Full replacement.** The AVPlayer-based `ShortsPlayerView`/`PlaybackViewModel` pipeline for Shorts is removed entirely — no fallback path. |
| UI/feature scope | Keep the existing Shorts paging UI (swipe gestures, index badge, title/channel, play/pause, transitions) unchanged. Add select TOS-only features (see Feature Parity Scope). |
| Mini-player | Not supported for Shorts. Dismissing/backgrounding stops playback, matching current behavior. |
| End-of-video behavior | Preserve current behavior: replicate `PlaybackViewModel.handlePlaybackEnd()`'s decision tree (loop / autoplay-advance / freeze) via the TOS embed's `ended` event. |
| Code-structure approach | New, parallel `ShortsEmbedPlayerViewModel` — isolated from `TOSPlayerViewModel` (the production-default regular-video player). Some code duplication accepted in exchange for zero regression risk to the regular-video path. A future architecture-deepening pass can extract a shared `TOSEmbedEngine` once both are stable in production. |

## Architecture

### New view model: `ShortsEmbedPlayerViewModel`

New file (e.g. `Sources/iPocketTube/ViewModels/ShortsEmbedPlayerViewModel.swift`). Owns **one persistent `WKWebView`** for the lifetime of a `ShortsPlayerView` session (not one per Short).

- **Configuration** mirrors `TOSPlayerViewModel.swift:203-210`: `allowsInlineMediaPlayback = true`, `allowsAirPlayForMediaPlayback = true`, `mediaTypesRequiringUserActionForPlayback = []`, transparent background (`isOpaque = false`, clear `backgroundColor`).
- **Injected user scripts**: the same `webkitHiderJS` (hides `window.webkit` from YouTube's WKWebView-detection) and `stateDetectionJS` (polls `document.querySelector('video')`, watches `.ytp-error` via `MutationObserver`, posts `ready`/`tick`/`stateChange`/`error`/`autoUnmuted` via `window.__nativeYTCallback.postMessage`), injected `forMainFrameOnly: false` so they apply to the cross-origin YouTube iframe.
- **HTML wrapper**: same pattern as `TOSPlayerViewModel.swift:427-453` — `<iframe id="yt" src="https://www.youtube.com/embed/{videoId}?...">` loaded via `loadHTMLString(_:baseURL: https://www.example.com)`, loaded once at session start pointed at `videos[startIndex]`.
- **New method `loadShort(video: Video)`** — the core addition not present in `TOSPlayerViewModel`:
  1. If watch-progress tracking is implemented (see Feature Parity Scope — "mark as watched", not resume-position), record the outgoing video's watched progress.
  2. Reset local `@Observable` state: `playerState = .unstarted`, `duration = 0`, `isReady = false`, `embedFrameInfo = nil`, clear SponsorBlock segments.
  3. `eval("document.getElementById('yt').src = '<new embed URL>'")` — navigates only the iframe, not the WKWebView's main document.
  4. The already-running `stateDetectionJS` polling loop detects the new `<video>` element and posts a fresh `"ready"` within its ~250ms cycle (injected scripts re-apply per-frame-navigation).
- **Playback commands** (`play`/`pause`/`seekTo`/`setPlaybackRate`) reuse the `eval()`-targeting-`embedFrameInfo` pattern from `TOSPlayerViewModel.swift:292-388`.

### New host view: `ShortsTOSWebView`

A `UIViewRepresentable` wrapping the WKWebView, mirroring however `TOSPlayerView.swift` hosts its WKWebView.

### `ShortsPlayerView` changes

Structure preserved, engine swapped:
- `@State var vm: PlaybackViewModel` → `@State var vm: ShortsEmbedPlayerViewModel`
- `PlayerAVLayerView(player: vm.player, ...)` → `ShortsTOSWebView(vm: vm)`
- `ShortsPlayerView+Navigation.swift`'s `loadVideo(at:)` calls `vm.loadShort(video:)` instead of `vm.load(video:)`
- Swipe gesture (`SwipeGestureOverlay`), `ShortsNavigation.targetIndex`, slide/cross-fade transitions, and next-2 metadata prefetch via `VideoPreloadCache` — **all unchanged**.

## Feature Parity Scope

| Feature | Port to Shorts? | Reasoning |
|---|---|---|
| SponsorBlock auto-skip | **Yes** | Some Shorts have sponsor segments; reuses `tick`-driven skip-check against `embedFrameInfo`, core to the robustness motivation. |
| Watch history — resume position | **No** | Low value for <60s clips; current AVPlayer Shorts pipeline doesn't do this either. |
| Watch history — mark as watched / progress | **Yes, if cheap** | Keep "continue watching" feed accuracy if it's a simple API call not coupled to the player engine. |
| Like/Dislike | **Out of scope (follow-up)** | Current Shorts overlay has no like/dislike UI — net-new UI surface, not part of this engine port. |
| Comments | **Out of scope (follow-up)** | Same — net-new UI surface. |
| Sleep timer | **Yes, automatic** | Sleep timer calls `pause()` on whatever's playing; works automatically once `ShortsEmbedPlayerViewModel.pause()` exists. |

## Data Flow

**Swipe → load new Short:**
1. User swipes → `SwipeGestureOverlay` → `ShortsNavigation.targetIndex(...)` → `goTo(nextIndex)` (unchanged).
2. `goTo` calls `vm.loadShort(video: videos[nextIndex])`: saves watch-progress for the outgoing video (if progress tracking is enabled), resets `@Observable` state, and `eval()`s the iframe's `src` to the new video's embed URL.
3. `stateDetectionJS` detects the new `<video>` element within ~250ms and posts `"ready"`.
4. `handleScriptMessage("ready")` captures the new `embedFrameInfo`, sets `duration`/`isReady = true`, kicks off SponsorBlock fetch for the new video, and begins the muted-autoplay-then-unmute dance (same as the regular TOS player).
5. The existing slide/cross-fade transition plays concurrently — if `"ready"` arrives within the animation window the swap is invisible; otherwise the new Short's frame is briefly blank/loading until `"ready"` (see Error Handling for the timeout fallback).

**Ongoing playback:**
- Periodic `"tick"` messages update `currentTime`/`playerState` and drive SponsorBlock skip-checks, identical to the regular TOS player.

**End of video:**
- `"stateChange"` → `ended` → `onEnded` callback replicates `PlaybackViewModel.handlePlaybackEnd()`'s decision tree (`PlaybackViewModel+Navigation.swift:114-163`) against the Shorts array instead of `relatedVideos`/`CurrentQueueStore`:
  - `settings.loopEnabled` → `seekTo(0)` + `play()` (replay in place)
  - else → advance via the same path as swipe-up (`goTo(currentIndex + 1)`), or mirror today's "exhausted" behavior (freeze / `videoEnded = true`) if at the end of the array.

**Dismiss:**
- `onDisappear` → `vm.pause()` via `eval()` + `webView.pauseAllMediaPlayback()` (same dual approach as the regular TOS player) — no mini-player handoff.

## Error Handling

- **Per-Short load failure** (`"error"` message — YouTube codes 100 *not found*, 101/150 *embedding disabled*, 153 *config error*, etc.): show the existing error banner (`ShortsPlayerView+Overlay.swift:182-190`) for ~1-2s, then auto-advance to the next Short via the same path as swipe-up. Most of these errors are permanent for that video, so skipping is the correct recovery for a continuous feed.
- **`"ready"` timeout** (~8-10s without a `"ready"` after an iframe-src-swap — covers network failures, slow connections, or silent embed failures with no `.ytp-error` overlay): treated identically to a load failure — error banner, then auto-advance.
- **Logging**: log these failures via Crashlytics (video id + error code/timeout), mirroring the existing stall-logging pattern at `PlaybackViewModel+Loading.swift:938` (bug #193) — gives visibility into real-world embed failure rates.
- **Out of scope for v1**: mid-playback stall detection (e.g. `playerState` stuck at `.buffering`). The regular TOS player doesn't have this either.

## Testing Strategy

**Unit tests** (`iPocketTubeTests`):
- Existing Shorts tests (`ShortsNavigationTests`, `ShortsVerticalThumbnailTests`, `HideShortsFilterTests`, `FEShortsClientRegressionTests`, `ShortsRowSectionDataTests`) are feed/filtering/navigation logic, independent of the player engine — remain unchanged.
- New: extract embed-URL construction (`videoId` → `https://www.youtube.com/embed/{id}?...`) as a pure function in `iPocketTubeCore` (same pattern as `HLSManifestParser`), unit-testable without a WKWebView.
- New: extract the end-of-video decision logic (loop / advance / freeze) as a pure function operating on `(settings, currentIndex, videos.count)`, testable the same way as `ShortsNavigation.targetIndex`.

**UI tests** (`iPocketTubeUITests`):
- New test: swipe through 2-3 Shorts, verify `"ready"`/`"tick"`/`"stateChange"` Darwin notifications fire for *each* loaded Short — proves the iframe-src-swap actually re-triggers the JS bridge per swap. Marked with the `AGENT-POST-RUN-CHECK: ui-tests-with-logs` comment per that skill's standard.
- Existing Shorts feed UI tests (selection, filtering) should be unaffected by the engine swap.

**Critical pre-work — validate the core assumption first:**
This design hinges on one unverified mechanic: that setting `document.getElementById('yt').src = '<new embed URL>'` on a cross-origin iframe inside a WKWebView (a) actually navigates the iframe, (b) re-triggers the injected `forMainFrameOnly: false` user scripts for the new frame, and (c) produces a fresh `"ready"` message — repeatedly, across many rapid swaps, without leaking memory or accumulating stale JS state/timers from the previous video.

This is **task #1 of the implementation plan**: a standalone spike that loads the TOS HTML wrapper, swaps the iframe `src` 3-4 times in a row, and confirms via logs that `"ready"`/`"tick"` fire correctly each time with no leftover state from the prior video. If this doesn't work as expected, stop and revisit the architecture (e.g. the preload-pool approach considered and deferred above) before building the rest.
