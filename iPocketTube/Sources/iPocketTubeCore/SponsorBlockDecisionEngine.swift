// MARK: - SponsorBlockDecisionEngine
//
// Pure "what should happen at this playback time" decision logic, shared
// between SponsorBlockSkipManager (AVPlayer-based, standard player) and
// TOSPlayerViewModel+SponsorBlock (JS-tick-based, TOS player). Each adapter
// keeps its own seek mechanism, logging, and async-confirmation plumbing —
// only the decision moves here.

/// What `SponsorBlockDecisionEngine.decide(...)` says should happen at the
/// current playback time.
public enum SponsorSkipDecision: Equatable {
    case clearToast
    case showToast(SponsorSegment)
    case skip(to: Double, segment: SponsorSegment)
    case skipToPlaybackEnd(segment: SponsorSegment)
    /// A skip segment is active but a skip is already in flight — do nothing.
    case none
}

public enum SponsorBlockDecisionEngine {
    /// Pure function: given the current time, loaded segments, settings, and
    /// whether a skip is already in flight, decide what should happen.
    /// `duration <= 0` disables the end-of-video special case (treated as
    /// "unknown duration").
    public static func decide(
        at time: Double,
        segments: [SponsorSegment],
        settings: AppSettings,
        isSkipInProgress: Bool,
        duration: Double
    ) -> SponsorSkipDecision {
        guard settings.sponsorBlockEnabled else { return .clearToast }
        guard let seg = segments.first(where: { time >= $0.start && time < $0.end }) else {
            return .clearToast
        }
        switch settings.sponsorAction(for: seg.category) {
        case .skip:
            guard !isSkipInProgress else { return .none }
            if duration > 0 && seg.end >= duration - 2.0 {
                return .skipToPlaybackEnd(segment: seg)
            }
            return .skip(to: seg.end, segment: seg)
        case .showToast:
            return .showToast(seg)
        case .nothing:
            return .clearToast
        }
    }
}
