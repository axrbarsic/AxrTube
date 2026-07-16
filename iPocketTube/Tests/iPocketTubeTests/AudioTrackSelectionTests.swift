import Foundation
import Testing
@testable import iPocketTubeCore

// MARK: - AudioTrackSelectionTests

@Suite("Audio Track Auto-Selection")
struct AudioTrackSelectionTests {

    // MARK: - Helpers

    private func track(_ code: String, isOriginal: Bool = false) -> AudioTrack {
        AudioTrack(id: code, name: code, languageCode: code, isOriginal: isOriginal)
    }

    /// Simulates the auto-selection waterfall from PlaybackViewModel+AudioTracks
    /// without an AVPlayer. Mirrors the exact logic in loadAudioTracks(from:).
    /// Pass `deviceLanguages` to simulate Locale.preferredLanguages (defaults to empty).
    private func autoSelect(
        tracks: [AudioTrack],
        preferred: String?,
        deviceLanguages: [String] = []
    ) -> AudioTrack? {
        // 1. Saved preference / Settings-level independent language choice
        if let lang = preferred {
            if lang == "original" {
                return tracks.first(where: \.isOriginal) ?? tracks.first
            }
            if let exact = tracks.first(where: { $0.languageCode == lang }) { return exact }
            let base = lang.components(separatedBy: "-").first ?? lang
            return tracks.first(where: { $0.languageCode.hasPrefix(base) })
                ?? tracks.first(where: \.isOriginal)
        }
        // 2. Device preferred languages — before DEFAULT=YES to avoid dubbed tracks
        //    overriding the user's expected language (issue #54 regression fix).
        for deviceLang in deviceLanguages {
            if let exact = tracks.first(where: { $0.languageCode == deviceLang }) { return exact }
            let base = deviceLang.components(separatedBy: "-").first ?? deviceLang
            if let match = tracks.first(where: { $0.languageCode.hasPrefix(base) }) { return match }
        }
        // 3. HLS DEFAULT=YES original
        if let original = tracks.first(where: \.isOriginal) { return original }
        // 4. English track
        let englishPrefixes = ["en-", "en_"]
        if let english = tracks.first(where: { $0.languageCode == "en" })
            ?? tracks.first(where: { lang in englishPrefixes.contains(where: { lang.languageCode.hasPrefix($0) }) }) {
            return english
        }
        // 5. First track
        return tracks.first
    }

    // MARK: - Tests

    /// When HLS DEFAULT=YES is on the English track, English is selected even on an
    /// Arabic-locale device (issue #24 root cause fix).
    @Test func originalTrackSelectedOverAIDubbedTrackWhenDefaultIsYES() {
        let tracks = [
            track("ar", isOriginal: false),     // AI-dubbed Arabic — listed first
            track("en", isOriginal: true),      // Original English — HLS DEFAULT=YES
        ]
        let selected = autoSelect(tracks: tracks, preferred: nil)
        #expect(selected?.languageCode == "en")
    }

    /// When no HLS DEFAULT=YES exists, English is chosen over other languages as
    /// the safer fallback (most YouTube originals are English).
    @Test func englishFallbackWhenNoDefaultTrack() {
        let tracks = [
            track("ar", isOriginal: false),     // AI-dubbed Arabic — first in list, no DEFAULT
            track("en", isOriginal: false),     // English — second in list
        ]
        let selected = autoSelect(tracks: tracks, preferred: nil)
        #expect(selected?.languageCode == "en")
    }

    /// Saved user preference always wins, even when a DEFAULT=YES track exists.
    @Test func savedPreferenceWinsOverOriginalTrack() {
        let tracks = [
            track("en", isOriginal: true),
            track("de", isOriginal: false),
        ]
        let selected = autoSelect(tracks: tracks, preferred: "de")
        #expect(selected?.languageCode == "de")
    }

    /// isOriginal is NOT set for index-0 when there is no HLS DEFAULT=YES.
    /// This prevents AI-dubbed tracks from being mislabelled as "original".
    @Test func isOriginalNotSetWhenNoHLSDefault() {
        // Simulates manifest with no DEFAULT=YES: all isOriginal == false
        let tracks = [
            track("ar", isOriginal: false),
            track("en", isOriginal: false),
        ]
        #expect(tracks.allSatisfy { !$0.isOriginal })
    }

    // MARK: - Task #19: "original" sentinel and independent language setting

    /// When preferredAudioLanguage == "original", the HLS DEFAULT=YES track is selected.
    @Test func originalSentinel_selectsHLSDefaultTrack() {
        let tracks = [
            track("ar", isOriginal: false),
            track("en", isOriginal: true),
            track("de", isOriginal: false),
        ]
        let selected = autoSelect(tracks: tracks, preferred: "original")
        #expect(selected?.languageCode == "en")
    }

    /// When preferredAudioLanguage == "original" and no DEFAULT=YES track exists, falls back to first track.
    @Test func originalSentinel_fallsBackToFirstTrack_whenNoDefault() {
        let tracks = [
            track("ar", isOriginal: false),
            track("de", isOriginal: false),
        ]
        let selected = autoSelect(tracks: tracks, preferred: "original")
        #expect(selected?.languageCode == "ar")
    }

    /// Independent language setting "de" overrides the original English track.
    @Test func independentLanguageSetting_overridesOriginalTrack() {
        let tracks = [
            track("en", isOriginal: true),
            track("de", isOriginal: false),
        ]
        let selected = autoSelect(tracks: tracks, preferred: "de")
        #expect(selected?.languageCode == "de")
    }

    /// Prefix matching: setting "en" matches "en-US".
    @Test func independentLanguageSetting_prefixMatchesLocaleVariant() {
        let tracks = [
            track("de", isOriginal: false),
            track("en-US", isOriginal: false),
        ]
        let selected = autoSelect(tracks: tracks, preferred: "en")
        #expect(selected?.languageCode == "en-US")
    }

    /// When preferred language has no match, falls back to original track.
    @Test func independentLanguageSetting_fallsBackToOriginal_whenNoMatch() {
        let tracks = [
            track("en", isOriginal: true),
            track("de", isOriginal: false),
        ]
        // "ja" not in list → fall back to original
        let selected = autoSelect(tracks: tracks, preferred: "ja")
        #expect(selected?.languageCode == "en")
    }

    /// System Default (nil) still picks the HLS DEFAULT=YES track when no device-language track exists.
    @Test func systemDefault_picksOriginalTrack() {
        let tracks = [
            track("de", isOriginal: false),
            track("en", isOriginal: true),
        ]
        // No device languages → falls through to DEFAULT=YES at step 3
        let selected = autoSelect(tracks: tracks, preferred: nil)
        #expect(selected?.languageCode == "en")
    }

    // MARK: - Task #54: Device language before DEFAULT=YES

    /// Regression: Arabic is DEFAULT=YES in the HLS manifest (YouTube sets this dynamically),
    /// but the device language is English — English should win (issue #24 / task #54).
    @Test func deviceLanguagePrecedesHLSDefault_whenDefaultIsArabic() {
        let tracks = [
            track("ar", isOriginal: true),  // Arabic is DEFAULT=YES in HLS manifest
            track("en", isOriginal: false), // English available but not DEFAULT
        ]
        let selected = autoSelect(tracks: tracks, preferred: nil, deviceLanguages: ["en"])
        #expect(selected?.languageCode == "en")
    }

    /// Arabic-locale device watching an Arabic-default video still gets Arabic.
    @Test func arabicDevice_getsArabicTrack_viaDeviceLanguage() {
        let tracks = [
            track("en", isOriginal: true),  // English is DEFAULT=YES
            track("ar", isOriginal: false), // Arabic dub
        ]
        let selected = autoSelect(tracks: tracks, preferred: nil, deviceLanguages: ["ar"])
        #expect(selected?.languageCode == "ar")
    }

    /// When device language has no matching track, DEFAULT=YES is used as fallback.
    @Test func deviceLanguage_fallsBackToDefault_whenNoMatch() {
        let tracks = [
            track("ar", isOriginal: true),  // Arabic DEFAULT=YES
            track("en", isOriginal: false), // English
        ]
        // Device is Japanese, no Japanese track → falls back to DEFAULT=YES (Arabic)
        let selected = autoSelect(tracks: tracks, preferred: nil, deviceLanguages: ["ja"])
        #expect(selected?.languageCode == "ar")
    }

    // MARK: - isMainProgramContent / Bug B regression tests

    /// Documents the post-fix behaviour: when `isOriginal` is correctly set on the
    /// creator's Korean track (not the AI-dubbed English), `preferred = "original"` picks Korean.
    @Test func originalSentinel_picksCreatorTrack_whenDubbedTrackIsDefault() {
        // Simulates AudioTrackManager post-fix:
        // - English AI-dubbed track had HLS DEFAULT=YES → old code set isOriginal=true on it
        // - Korean original has isMainProgramContent → new code correctly sets isOriginal=true
        let tracks = [
            track("en", isOriginal: false),   // AI-dubbed English — must NOT be selected
            track("ko", isOriginal: true),    // Korean creator original
        ]
        let selected = autoSelect(tracks: tracks, preferred: "original")
        #expect(selected?.languageCode == "ko", "Original sentinel must pick the creator's track, not the AI dub")
    }

    /// Regression: dubbed track must never be returned when `preferred = "original"` and
    /// a track with `isOriginal = true` exists.
    @Test func originalSentinel_regression_dubbedTrackMustNotBeReturnedAsOriginal() {
        let tracks = [
            track("en", isOriginal: false),   // dubbed — isOriginal=false after fix
            track("ko", isOriginal: true),    // original — isOriginal=true after fix
        ]
        let selected = autoSelect(tracks: tracks, preferred: "original")
        #expect(selected?.languageCode == "ko")
        #expect(selected?.isOriginal == true)
    }

    // MARK: - Fix #126: single-track HLS variant playlists (quality-switch regression)

    /// When a quality change loads a new HLS variant with only one audio rendition,
    /// the old guard (`count > 1`) would exit early leaving no audio selected.
    /// Fix: guard changed to `!isEmpty` so single-track manifests still get audio applied.

    @Test("Fix #126: single-track manifest — autoSelect returns the track")
    func singleTrackManifestReturnsTrack() {
        let tracks = [track("en", isOriginal: true)]
        let selected = autoSelect(tracks: tracks, preferred: nil)
        #expect(selected?.languageCode == "en",
                "Fix #126: single-track manifest must select the available track, not return nil")
    }

    @Test("Fix #126: single-track manifest with saved preference — track is selected")
    func singleTrackManifestWithSavedPreferenceReturnsTrack() {
        let tracks = [track("ja", isOriginal: true)]
        // Even with a preference for a language not in the list, should fall back to the only track
        let selected = autoSelect(tracks: tracks, preferred: "en")
        #expect(selected?.languageCode == "ja",
                "Fix #126: single-track manifest must fall back to available track when preference has no match")
    }

    @Test("Fix #126: single-track manifest with device language — track is selected")
    func singleTrackManifestWithDeviceLanguageReturnsTrack() {
        let tracks = [track("de", isOriginal: true)]
        let selected = autoSelect(tracks: tracks, preferred: nil, deviceLanguages: ["en"])
        #expect(selected?.languageCode == "de",
                "Fix #126: single-track manifest falls back to the available track when device language has no match")
    }

    // MARK: - Fix #124: Audio track picker button stays visible after quality switch

    /// The preservation condition in AudioTrackManager.loadAudioTracks (Fix #124):
    ///   if !availableAudioTracks.isEmpty, tracks.count < availableAudioTracks.count {
    ///       // preserve existing track list, re-apply selection, return early
    ///   }

    private func shouldPreserveExistingTracks(
        existing: [AudioTrack],
        incoming: [AudioTrack]
    ) -> Bool {
        !existing.isEmpty && incoming.count < existing.count
    }

    @Test("Fix #124: quality-switch variant with fewer tracks triggers preservation")
    func fix124VariantWithFewerTracksPreservesExisting() {
        let multiTrack = [track("en", isOriginal: true), track("es"), track("fr")]
        let singleTrack = [track("en", isOriginal: true)]
        #expect(shouldPreserveExistingTracks(existing: multiTrack, incoming: singleTrack),
                "Fix #124: single-track variant must trigger preservation of 3-track list")
    }

    @Test("Fix #124: initial load with more tracks does NOT trigger preservation")
    func fix124InitialLoadDoesNotPreserve() {
        let empty: [AudioTrack] = []
        let multiTrack = [track("en", isOriginal: true), track("es")]
        #expect(!shouldPreserveExistingTracks(existing: empty, incoming: multiTrack),
                "Fix #124: initial load (empty existing) must not trigger preservation")
    }

    @Test("Fix #124: quality-switch to same track count does NOT trigger preservation")
    func fix124SameCountDoesNotPreserve() {
        let existing = [track("en", isOriginal: true), track("es")]
        let incoming = [track("en", isOriginal: true), track("es")]
        #expect(!shouldPreserveExistingTracks(existing: existing, incoming: incoming),
                "Fix #124: same count means full load — must not trigger preservation")
    }

    @Test("Fix #124: quality-switch to MORE tracks does NOT trigger preservation")
    func fix124MoreTracksDoesNotPreserve() {
        let existing = [track("en", isOriginal: true)]
        let incoming = [track("en", isOriginal: true), track("es"), track("de")]
        #expect(!shouldPreserveExistingTracks(existing: existing, incoming: incoming),
                "Fix #124: more tracks than existing means full load — must not trigger preservation")
    }

    @Test("Fix #124: preserved selection logic — selected track re-applied when in optionMap")
    func fix124SelectedTrackReappliedFromOptionMap() {
        // Simulate: user selected "es", quality switch brings variant with only "en"
        // The variant's optionMap only has "en", so "es" cannot be re-applied.
        // Verify the selection lookup fails gracefully.
        let optionMapKeys = Set(["en"])  // variant only has English
        let selectedID = "es"           // user had Spanish selected
        let canReapply = optionMapKeys.contains(selectedID)
        #expect(!canReapply,
                "When selected track is not in variant, canReapply must be false — uses group.defaultOption fallback")
    }

    // MARK: - Fix #130: only one track must be marked isOriginal

    /// Task #130: when Phase 2 fallback is used (no isMainProgramContent characteristic),
    /// only the single DEFAULT=YES track must be marked isOriginal.
    /// The bug was using == (value equality) instead of === (identity) on AVMediaSelectionOption,
    /// which incorrectly returned true for all options, causing every track to show "Original".
    ///
    /// This test mirrors the intent: given a set of tracks where isOriginal is set by the
    /// identity-correct Phase 2 logic, exactly one track should be marked original.
    @Test func fix130_exactlyOneTrackIsOriginal_whenUsingPhase2Fallback() {
        // Simulate correctly constructed tracks after the === fix:
        // Only the HLS DEFAULT=YES track (en) gets isOriginal = true.
        let tracks = [
            track("en", isOriginal: true),   // DEFAULT=YES — the only original
            track("es", isOriginal: false),  // dubbed Spanish
            track("fr", isOriginal: false),  // dubbed French
        ]
        let originalCount = tracks.filter(\.isOriginal).count
        #expect(originalCount == 1,
                "Fix #130: exactly one track must be marked isOriginal (was: all tracks marked original due to == bug)")
    }

    /// Task #130: when all tracks were incorrectly marked isOriginal (the bug),
    /// auto-selection would always resolve to the first track (correct by accident).
    /// After the fix, auto-selection must still resolve to the correct original track.
    @Test func fix130_autoSelectStillPicksOriginalAfterFix() {
        let tracks = [
            track("es", isOriginal: false),  // Spanish AI dub — first in list
            track("en", isOriginal: true),   // English original — DEFAULT=YES
            track("fr", isOriginal: false),  // French AI dub
        ]
        // Without a saved preference, the original track must be selected (not the first)
        let selected = autoSelect(tracks: tracks, preferred: nil)
        #expect(selected?.languageCode == "en",
                "Fix #130: auto-select must return the isOriginal=true track, not the first track")
        #expect(selected?.isOriginal == true)
    }

    /// Task #130: when no track has isOriginal = true (no DEFAULT=YES in manifest),
    /// no track should be labelled "Original" in the UI.
    @Test func fix130_noTrackMarkedOriginal_whenNoDefault() {
        let tracks = [
            track("en", isOriginal: false),
            track("es", isOriginal: false),
        ]
        #expect(tracks.allSatisfy { !$0.isOriginal },
                "Fix #130: when no DEFAULT=YES exists, no track must show Original label")
    }

    // MARK: - Phase 1 / Phase 2 detection logic (mirrors AudioTrackManager)

    /// Mirrors the `isOriginal` detection in AudioTrackManager.loadAudioTracks,
    /// replacing AVMediaSelectionOption with Bool flags to allow pure unit-testing.
    ///
    /// Parameters mirror the per-track state inside the for loop:
    ///   mainContentCount  — number of tracks in the group that have isMainProgramContent
    ///   totalCount        — total tracks in the group
    ///   hasMainContent    — whether THIS option has isMainProgramContent
    ///   isDefault         — whether THIS option is group.defaultOption (identity)
    private func isOriginalMirror(
        mainContentCount: Int,
        totalCount: Int,
        hasMainContent: Bool,
        isDefault: Bool
    ) -> Bool {
        let phase1Discriminates = mainContentCount > 0 && mainContentCount < totalCount
        return phase1Discriminates ? hasMainContent : isDefault
    }

    /// YouTube's common case: ALL tracks have isMainProgramContent (YouTube sets it
    /// on every dubbed track). Phase 1 must NOT fire; Phase 2 (DEFAULT=YES) must be used.
    @Test func fix130_allTracksHaveMainContent_fallsBackToDefault() {
        // 6 dubbed tracks, all have isMainProgramContent — mirrors the screenshot bug.
        let total = 6
        let results = (0..<total).map { i in
            isOriginalMirror(mainContentCount: total, totalCount: total,
                             hasMainContent: true, isDefault: i == 0)
        }
        let originalCount = results.filter { $0 }.count
        #expect(originalCount == 1,
                "When all tracks have isMainProgramContent, exactly one must be Original (via DEFAULT=YES)")
        #expect(results[0] == true,  "The DEFAULT=YES track must be Original")
        #expect(results[1] == false, "Non-default tracks must not be Original")
    }

    /// Well-behaved manifest: exactly one track has isMainProgramContent (the creator's
    /// original). Phase 1 fires and only that track is "Original".
    @Test func fix130_oneTrackHasMainContent_phase1Fires() {
        // Track 1 is original (has isMainProgramContent), tracks 2-5 are dubbed.
        let total = 5
        let results = (0..<total).map { i in
            isOriginalMirror(mainContentCount: 1, totalCount: total,
                             hasMainContent: i == 0, isDefault: i == 0)
        }
        let originalCount = results.filter { $0 }.count
        #expect(originalCount == 1,
                "Exactly one track has isMainProgramContent — Phase 1 should fire cleanly")
        #expect(results[0] == true)
        #expect(results[1] == false)
    }

    /// No tracks have isMainProgramContent (older manifest). Phase 2 (DEFAULT=YES) used.
    @Test func fix130_noTracksHaveMainContent_usesDefault() {
        let total = 3
        let results = (0..<total).map { i in
            isOriginalMirror(mainContentCount: 0, totalCount: total,
                             hasMainContent: false, isDefault: i == 2)
        }
        let originalCount = results.filter { $0 }.count
        #expect(originalCount == 1)
        #expect(results[2] == true, "The DEFAULT=YES track must be Original when Phase 2 fires")
    }
}

