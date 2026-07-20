#if !os(tvOS)
import Foundation
import CoreFoundation
import os
import iPocketTubeCore

private let tosLog = Logger(subsystem: "com.void.ipockettube.app", category: "TOSPlayer")

// MARK: - PendingSkipLog

/// Bridges an auto-skip's "before" log line to its asynchronously-observed "after" line.
///
/// `seekTo(_:)` is a fire-and-forget `evaluateJavaScript` call with no completion
/// handler — the IFrame embed has no seek-completion callback we can hook into. So
/// the only way to learn where playback actually landed is to watch the next few
/// "tick" messages until the reported `currentTime` catches up to the seek target
/// (see the "tick" case in `handleScriptMessage` and `logSkipLanding`). This struct
/// carries the "before" side of that comparison across that async gap.
struct PendingSkipLog {
    let category: SponsorSegment.Category
    let segmentStart: Double
    let segmentEnd: Double
    /// Playback position at the instant the skip was triggered ("before").
    let beforeTime: Double
    /// Where we told the player to seek to (== segmentEnd, named separately for clarity
    /// at the call site and in case future skip strategies target something other than
    /// the segment's end, e.g. a small buffer past it).
    let targetTime: Double
    /// Number of "tick" messages observed since the seek was fired, without yet
    /// landing — used to detect & log a seek that silently never takes effect.
    var ticksWaited: Int = 0
}

// MARK: - SponsorBlock
//
// Cache-first segment loading + tick-driven skip/toast logic for the TOS player.
// Mirrors the standard player's SponsorBlock phase in PlaybackViewModel+Loading
// and PlaybackViewModel+SponsorBlock (see docs/tos-sponsorskip.md), adapted to
// the TOS player's polled-tick architecture (no AVPlayer periodic-time-observer —
// segment checks ride on the "tick" messages relayed by handleScriptMessage).

extension TOSPlayerViewModel {

    /// Cache-first load mirroring the standard player's SponsorBlock phase in
    /// `PlaybackViewModel+Loading` (see docs/tos-sponsorskip.md): a cache hit — even a
    /// stale one — is applied immediately (zero network cost on the happy path), with
    /// stale entries silently revalidated in the background. A full miss falls back to
    /// a live fetch, whose result is stored in `VideoPreloadCache` so the standard
    /// player and any future TOS session can reuse it too.
    func fetchSponsorSegments() async {
        guard settings.sponsorBlockEnabled,
              !settings.activeSponsorCategories.isEmpty
        else { return }

        // UI-testing deterministic injection — mirrors the
        // --uitesting-inject-related-video-ids= seam in PlaybackViewModel+Loading.
        // Real SponsorBlock data is keyed by videoId and the home feed picks a
        // *random* video, so a test can't rely on "the first video has segment X at
        // time Y" — and disabling SponsorBlock outright (as the smoke test does via
        // --uitesting-disable-sponsorblock) can't exercise this path at all. This seam
        // injects synthetic segments straight into `sponsorSegments`, bypassing cache
        // and network entirely, so a skip fires deterministically regardless of which
        // video loads or whether the live API has data for it.
        //
        // Format: "<start>-<end>:<category>[,<start>-<end>:<category>...]"
        //   e.g. "--uitesting-inject-sponsor-segments=2-6:sponsor"
        // <category> must match a SponsorSegment.Category rawValue (sponsor, selfpromo,
        // interaction, intro, outro, preview, filler, music_offtopic, poi_highlight).
        if let injectArg = ProcessInfo.processInfo.arguments.first(where: {
            $0.hasPrefix("--uitesting-inject-sponsor-segments=")
        }) {
            let raw = String(injectArg.dropFirst("--uitesting-inject-sponsor-segments=".count))
            let injected: [SponsorSegment] = raw.split(separator: ",").compactMap { spec in
                let parts = spec.split(separator: ":")
                guard parts.count == 2 else { return nil }
                let range = parts[0].split(separator: "-")
                guard range.count == 2,
                      let start = Double(range[0]),
                      let end = Double(range[1]),
                      let category = SponsorSegment.Category(rawValue: String(parts[1]))
                else { return nil }
                return SponsorSegment(start: start, end: end, category: category)
            }
            guard !injected.isEmpty else { return }
            sponsorSegments = injected
            let summary = injected
                .map { seg -> String in
                    let start = String(format: "%.1f", seg.start)
                    let end = String(format: "%.1f", seg.end)
                    return "\(seg.category.rawValue)[\(start)–\(end)s]"
                }
                .joined(separator: ", ")
            tosLog.notice("[SponsorBlock] UI-TEST INJECT — bypassing cache/network, applied \(injected.count) synthetic segment(s): \(summary)")
            return
        }

        let channelIsExcluded = channelId.map {
            settings.sponsorBlockExcludedChannels.keys.contains($0)
        } ?? false
        guard !channelIsExcluded else {
            tosLog.notice("[SponsorBlock] channel excluded — skipping for \(self.videoId)")
            return
        }

        let videoId = videoId
        let categories = settings.activeSponsorCategories
        let minDuration = settings.sponsorBlockMinSegmentDuration
        func filtered(_ segments: [SponsorSegment]) -> [SponsorSegment] {
            minDuration > 0 ? segments.filter { ($0.end - $0.start) >= minDuration } : segments
        }

        let cached = await VideoPreloadCache.shared.consume(videoId: videoId)
        if let cachedSegments = cached.sponsorSegments {
            let isStale = cached.staleFields.contains(.sponsorSegments)
            sponsorSegments = filtered(cachedSegments)
            tosLog.notice("[SponsorBlock] cache \(isStale ? "STALE" : "HIT") — applied \(self.sponsorSegments.count) segment(s) for \(videoId)")
            guard isStale else { return }
            // Revalidate silently — re-apply when it lands so a long-running session
            // picks up the refreshed list (mirrors Phase 2's stale-revalidation path).
            Task(priority: .background) { [weak self] in
                guard let self else { return }
                let fresh = await self.sponsorService.fetchSegments(videoId: videoId, categories: categories)
                await VideoPreloadCache.shared.store(sponsorSegments: fresh, for: videoId)
                await MainActor.run {
                    self.sponsorSegments = filtered(fresh)
                    tosLog.notice("[SponsorBlock] revalidated — \(self.sponsorSegments.count) segment(s) for \(videoId)")
                }
            }
            return
        }

        // Full miss — fetch live, store for reuse, then apply.
        let segments = await sponsorService.fetchSegments(videoId: videoId, categories: categories)
        await VideoPreloadCache.shared.store(sponsorSegments: segments, for: videoId)
        sponsorSegments = filtered(segments)
        tosLog.notice("[SponsorBlock] cache MISS — fetched & applied \(self.sponsorSegments.count) of \(segments.count) loaded segment(s) for \(videoId)")
    }

    /// Evaluates the current playback time against loaded segments and either
    /// auto-skips, shows a toast, or clears any active toast — driven by every
    /// "tick" message (see `handleScriptMessage`'s "tick" case).
    func checkSponsorSkip(at time: Double) {
        if let end = activeSkipEnd, time >= end { activeSkipEnd = nil }

        let decision = SponsorBlockDecisionEngine.decide(
            at: time,
            segments: sponsorSegments,
            settings: settings,
            isSkipInProgress: activeSkipEnd != nil,
            duration: duration
        )

        switch decision {
        case .clearToast:
            currentToastSegment = nil

        case .skip(let target, let seg):
            activeSkipEnd = seg.end
            currentToastSegment = nil

            // Full payload up front, "before" time included — this is the line to grep
            // for to correlate a skip with the segment that caused it. The "AFTER"/landing
            // line (logged from the "tick" handler once the seek is confirmed) carries the
            // matching beforeTime so the pair can be joined without timestamps.
            tosLog.notice("[SponsorBlock] skip TRIGGER category=\(seg.category.rawValue) action=skip segment=[\(seg.start, format: .fixed(precision: 1))s–\(seg.end, format: .fixed(precision: 1))s] (duration=\(seg.end - seg.start, format: .fixed(precision: 1))s) before=\(time, format: .fixed(precision: 2))s target=\(target, format: .fixed(precision: 2))s")
            pendingSkipLog = PendingSkipLog(
                category: seg.category,
                segmentStart: seg.start,
                segmentEnd: seg.end,
                beforeTime: time,
                targetTime: target
            )
            seekTo(target)
            // Cross-process signal for XCTest (mirrors .ready/.playing/.tickstarted below) —
            // lets a UI test `wait(for:)` the skip deterministically instead of guessing
            // a sleep duration long enough to cover "segment start + startup latency".
            CFNotificationCenterPostNotification(
                CFNotificationCenterGetDarwinNotifyCenter(),
                CFNotificationName("com.void.ipockettube.tosplayer.sponsorskip" as CFString),
                nil, nil, true
            )

        case .skipToPlaybackEnd(let seg):
            // TOS has no handlePlaybackEnd() equivalent (loop/autoplay/queue-next are
            // standard-player-only concepts) — and the natural "ended" stateChange
            // already fires once the video plays through. Rather than seeking past the
            // end (which previously left TOS with no fallback at all), let playback
            // continue through this last ~2s to its real end.
            currentToastSegment = nil
            if lastLoggedNearEndSegment?.start != seg.start || lastLoggedNearEndSegment?.category != seg.category {
                lastLoggedNearEndSegment = seg
                tosLog.notice("[SponsorBlock] near-end segment — letting playback continue to natural end category=\(seg.category.rawValue) segment=[\(seg.start, format: .fixed(precision: 1))s–\(seg.end, format: .fixed(precision: 1))s]")
            }

        case .showToast(let seg):
            // Log only on the transition into a new segment — `checkSponsorSkip` runs on
            // every ~250ms tick while inside the segment, and logging here unconditionally
            // would spam ~4 identical lines/second for the toast's entire visible window.
            if lastLoggedToastSegment?.start != seg.start || lastLoggedToastSegment?.category != seg.category {
                lastLoggedToastSegment = seg
                tosLog.notice("[SponsorBlock] toast SHOW category=\(seg.category.rawValue) action=showToast segment=[\(seg.start, format: .fixed(precision: 1))s–\(seg.end, format: .fixed(precision: 1))s] at t=\(time, format: .fixed(precision: 2))s")
            }
            currentToastSegment = seg

        case .none:
            break
        }
    }

    /// Watches for the landing of an in-flight auto-skip seek and logs the "after" side
    /// of the before/after pair once confirmed (or a timeout if it never lands).
    ///
    /// Called from the "tick" handler on every received tick — `pendingSkipLog` is `nil`
    /// the overwhelming majority of the time, so this is a cheap no-op outside an
    /// in-flight skip. See `PendingSkipLog` for why this async confirmation is necessary
    /// (no seek-completion callback exists in the IFrame bridge).
    func logSkipLanding(at time: Double) {
        guard var pending = pendingSkipLog else { return }

        // "Landed" = the reported currentTime has caught up to the seek target (within
        // half a tick-interval of slack for YouTube's own seek-settling). A plain forward
        // tick from `beforeTime` could only reach this threshold by crossing the entire
        // segment in ~250ms, which min-segment-duration filtering makes implausible —
        // so reaching the threshold reliably indicates the seek (not natural playback)
        // moved us here.
        if time >= pending.targetTime - 0.5 {
            let skippedSeconds = time - pending.beforeTime
            tosLog.notice("[SponsorBlock] skip LANDED category=\(pending.category.rawValue) before=\(pending.beforeTime, format: .fixed(precision: 2))s after=\(time, format: .fixed(precision: 2))s skipped≈\(skippedSeconds, format: .fixed(precision: 2))s (target was \(pending.targetTime, format: .fixed(precision: 2))s, Δtarget=\(time - pending.targetTime, format: .fixed(precision: 2))s) ticksWaited=\(pending.ticksWaited)")
            pendingSkipLog = nil
            return
        }

        // Not landed yet — keep waiting, but only for so long. At ~250ms/tick, 16 ticks
        // is ~4s: generous for YouTube's seek-settling, but short enough that a real
        // failure-to-seek surfaces in the log quickly rather than hanging silently.
        pending.ticksWaited += 1
        if pending.ticksWaited > 16 {
            tosLog.notice("[SponsorBlock] skip TIMEOUT category=\(pending.category.rawValue) before=\(pending.beforeTime, format: .fixed(precision: 2))s target=\(pending.targetTime, format: .fixed(precision: 2))s — still at \(time, format: .fixed(precision: 2))s after \(pending.ticksWaited) ticks; seek may not have taken effect")
            pendingSkipLog = nil
        } else {
            pendingSkipLog = pending
        }
    }
}
#endif // !os(tvOS)
