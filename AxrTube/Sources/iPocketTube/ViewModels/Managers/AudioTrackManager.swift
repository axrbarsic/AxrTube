import AVFoundation
import os
import iPocketTubeCore

private let playerLog = CrashlyticsLogger(category: "Player")

// MARK: - AudioTrackDelegate

@MainActor
protocol AudioTrackDelegate: AnyObject {
    var settings: AppSettings { get set }
}

// MARK: - AudioTrackManager

/// Owns `availableAudioTracks`, `selectedAudioTrack`, `audioSelectionGroup`,
/// and `audioOptionsByID`. Logic migrated from PlaybackViewModel+AudioTracks.swift.
@MainActor
@Observable
final class AudioTrackManager {

    // MARK: - State

    var availableAudioTracks: [AudioTrack] = []
    var selectedAudioTrack: AudioTrack? = nil

    // AVMediaSelectionGroup is not Sendable — keep nonisolated(unsafe) on MainActor class
    @ObservationIgnored nonisolated(unsafe) var audioSelectionGroup: AVMediaSelectionGroup? = nil
    @ObservationIgnored var audioOptionsByID: [String: AVMediaSelectionOption] = [:]

    /// Called when the user selects a language track via the YT-EXT-AUDIO-CONTENT-ID path
    /// (YouTube HLS with per-language variant streams, not #EXT-X-MEDIA groups).
    /// The closure triggers an AVPlayerItem reload for the selected language.
    /// Reset to nil when loading a new video (reset() is called by PlaybackViewModel).
    @ObservationIgnored var onHLSLanguageChange: ((AudioTrack?) -> Void)?

    // MARK: - Dependencies

    @ObservationIgnored weak var delegate: (any AudioTrackDelegate)?
    let player: AVPlayer

    // MARK: - Init

    init(player: AVPlayer) {
        self.player = player
    }

    // MARK: - Interface

    func reset() {
        availableAudioTracks = []
        selectedAudioTrack = nil
        audioSelectionGroup = nil
        audioOptionsByID = [:]
        onHLSLanguageChange = nil
    }

    /// Switches to `track`, or resets to the HLS default when `nil`.
    /// Persists the language code in `AppSettings`.
    /// For the YT-EXT-AUDIO-CONTENT-ID HLS path (no audioSelectionGroup), fires
    /// onHLSLanguageChange so the caller can reload the AVPlayerItem with the right language.
    func selectAudioTrack(_ track: AudioTrack?) {
        selectedAudioTrack = track
        delegate?.settings.preferredAudioLanguage = track?.languageCode
        if let group = audioSelectionGroup {
            guard let item = player.currentItem else { return }
            if let track, let option = audioOptionsByID[track.id] {
                item.select(option, in: group)
            } else {
                item.selectMediaOptionAutomatically(in: group)
            }
        } else if let onChange = onHLSLanguageChange {
            // YT-EXT-AUDIO-CONTENT-ID path: reload AVPlayerItem filtered for selected language
            onChange(track)
        }
        playerLog.notice("Audio → \(track?.name ?? "Auto (preference cleared)")")
    }

    /// Populates available audio tracks from YouTube's YT-EXT-AUDIO-CONTENT-ID HLS manifest
    /// format (not #EXT-X-MEDIA groups). Auto-applies the user's saved language preference.
    /// Does NOT set audioSelectionGroup — track switching is handled via onHLSLanguageChange.
    func loadHLSVariantTracks(_ tracks: [AudioTrack]) {
        guard !tracks.isEmpty else { return }
        availableAudioTracks = tracks
        let preferred = delegate?.settings.preferredAudioLanguage
        if let pref = preferred,
           let preferredTrack = tracks.first(where: { $0.languageCode == pref }) {
            selectedAudioTrack = preferredTrack
        } else if let originalTrack = tracks.first(where: { $0.isOriginal }) {
            selectedAudioTrack = originalTrack
        } else {
            selectedAudioTrack = tracks.first
        }
        playerLog.notice("AudioTrackManager: loaded \(tracks.count) HLS variant track(s) — selected: \(selectedAudioTrack?.name ?? "nil")")
    }

    /// Loads alternate audio renditions from the HLS manifest of `item` and auto-applies
    /// the user's saved language preference.
    func loadAudioTracks(from item: AVPlayerItem) {
        Task { [weak self] in
            guard let self else { return }
            let asset = item.asset
            // Fix #126: HLS variant playlists (loaded when quality changes) expose only
            // one audio rendition. The previous guard `count > 1` silently exited,
            // leaving no audio option selected → silent video after a quality switch.
            // Use `!isEmpty` so a single-track manifest still gets its track applied.
            let group = try? await asset.loadMediaSelectionGroup(for: .audible)
            let groupDesc = group.map { "\($0.options.count) option(s)" } ?? "nil"
            playerLog.notice("AudioTrackManager: loadMediaSelectionGroup=\(groupDesc)")
            guard let group, !group.options.isEmpty else { return }
            var tracks: [AudioTrack] = []
            var optionMap: [String: AVMediaSelectionOption] = [:]

            // Pre-compute which options carry isMainProgramContent so we can decide
            // whether Phase 1 is discriminating before iterating.
            let mainContentOptions = group.options.filter {
                $0.hasMediaCharacteristic(.isMainProgramContent)
            }
            // Phase 1 is only useful when it discriminates: some (but not all) options
            // carry the characteristic. YouTube sometimes sets isMainProgramContent on
            // EVERY dubbed track, causing all to appear as "Original". In that case we
            // fall through to Phase 2 (HLS DEFAULT=YES identity check).
            let phase1Discriminates = !mainContentOptions.isEmpty
                && mainContentOptions.count < group.options.count

            let defaultLocale = group.defaultOption?.locale?.identifier
                ?? group.defaultOption?.extendedLanguageTag
                ?? (group.defaultOption != nil ? "present/no-locale" : "nil")
            // Verify defaultOption identity: it must be one of the options in group.options.
            // If not, the === comparison will always return false and phase-2 will silently fail.
            let defaultFoundInOptions = group.defaultOption.map { def in
                group.options.contains { $0 === def }
            } ?? true  // nil defaultOption is fine (phase-2 simply marks none as original)
            playerLog.notice("AudioTrackManager: \(group.options.count) option(s), phase1Discriminates=\(phase1Discriminates) (mainContent=\(mainContentOptions.count)) defaultOption=\(defaultLocale) defaultInOptions=\(defaultFoundInOptions)")

            for (_, option) in group.options.enumerated() {
                let locale = option.locale?.identifier
                    ?? option.extendedLanguageTag
                    ?? "unknown"
                let displayName = option.locale.flatMap { loc -> String? in
                    let name = Locale.current.localizedString(forLanguageCode: loc.identifier)
                    if let name, !name.isEmpty { return name }
                    // Fall back to English locale when the device locale cannot resolve the code.
                    return Locale(identifier: "en_US").localizedString(forLanguageCode: loc.identifier)
                } ?? locale
                let isMainContent = option.hasMediaCharacteristic(.isMainProgramContent)
                let isAuxiliary = option.hasMediaCharacteristic(.isAuxiliaryContent)
                // Phase 2: HLS DEFAULT=YES. Use locale/tag equality as fallback to ===
                // because some AVFoundation versions return a different instance for defaultOption.
                let isDefault = group.defaultOption.map { def in
                    def === option
                        || (def.locale != nil && def.locale == option.locale)
                        || (def.extendedLanguageTag != nil && def.extendedLanguageTag == option.extendedLanguageTag)
                } ?? false
                // Phase 1: use AVFoundation's authoritative "main program content" characteristic,
                // but ONLY when it discriminates (not all tracks carry it).
                // Phase 2: fall back to HLS DEFAULT=YES identity check.
                let isOriginal: Bool = phase1Discriminates ? isMainContent : isDefault
                playerLog.notice("  AudioOption: locale=\(locale) isMainContent=\(isMainContent) isAuxiliary=\(isAuxiliary) isDefault=\(isDefault) isOriginal=\(isOriginal) displayName=\(displayName)")
                let track = AudioTrack(id: locale, name: displayName,
                                       languageCode: locale, isOriginal: isOriginal)
                tracks.append(track)
                optionMap[locale] = option
            }
            var originalCount = tracks.filter(\.isOriginal).count
            playerLog.notice("AudioTrackManager: \(originalCount)/\(tracks.count) track(s) marked isOriginal=true after phase1/2")

            // Phase 3: when phase 1 and 2 both miss (YouTube sometimes omits DEFAULT=YES
            // and doesn't set isMainProgramContent distinctly), fall back to isAuxiliaryContent.
            // Dubbed tracks carry this characteristic; the creator's original does not.
            if originalCount == 0, tracks.count > 1 {
                let nonAuxiliaryLocales = optionMap.filter { _, opt in
                    !opt.hasMediaCharacteristic(.isAuxiliaryContent)
                }.map(\.key)
                playerLog.notice("AudioTrackManager: Phase 3 — \(nonAuxiliaryLocales.count) non-auxiliary track(s): \(nonAuxiliaryLocales.joined(separator: ", "))")
                if nonAuxiliaryLocales.count == 1, let locale = nonAuxiliaryLocales.first {
                    tracks = tracks.map { t in
                        AudioTrack(id: t.id, name: t.name, languageCode: t.languageCode,
                                   isOriginal: t.id == locale)
                    }
                    originalCount = 1
                    playerLog.notice("AudioTrackManager: Phase 3 — marked \(locale) as original")
                }
            }

            // Phase 4: last resort — YouTube consistently appends the creator's original
            // audio LAST in the HLS manifest when other tracks are AI dubs. Confirmed in
            // logs: all 13 tracks had isMainProgramContent=true, defaultOption=nil, and
            // the original English (en-US) was the final option.
            if originalCount == 0, let lastTrack = tracks.last {
                playerLog.notice("AudioTrackManager: Phase 4 — marking last track (\(lastTrack.id)) as original (YouTube puts creator audio last)")
                tracks = tracks.map { t in
                    AudioTrack(id: t.id, name: t.name, languageCode: t.languageCode,
                               isOriginal: t.id == lastTrack.id)
                }
                originalCount = 1
            }

            playerLog.notice("AudioTrackManager: final \(originalCount)/\(tracks.count) isOriginal=true")
            self.audioSelectionGroup = group
            self.audioOptionsByID = optionMap

            // Fix #124: When a quality switch loads a variant playlist with fewer
            // audio renditions than the original HLS master (e.g., a variant URL that
            // lacks EXT-X-MEDIA entries for alternate languages), preserve the existing
            // track list so the picker button stays visible. Re-apply the current
            // selection to the new item so audio continues correctly.
            if !self.availableAudioTracks.isEmpty, tracks.count < self.availableAudioTracks.count {
                let selectedID = self.selectedAudioTrack?.id
                if let selectedID, let option = optionMap[selectedID] {
                    item.select(option, in: group)
                } else if let defaultOption = group.defaultOption {
                    item.select(defaultOption, in: group)
                }
                playerLog.notice("Quality variant: \(tracks.count) audio rendition(s) vs \(self.availableAudioTracks.count) known — preserved track list, re-applied selection")
                return
            }

            self.availableAudioTracks = tracks

            let preferred = self.delegate?.settings.preferredAudioLanguage
            let autoSelect: AudioTrack? = {
                if let lang = preferred {
                    if lang == "original" {
                        return tracks.first(where: \.isOriginal) ?? tracks.first
                    }
                    if let exact = tracks.first(where: { $0.languageCode == lang }) { return exact }
                    let base = lang.components(separatedBy: "-").first ?? lang
                    return tracks.first(where: { $0.languageCode.hasPrefix(base) })
                        ?? tracks.first(where: \.isOriginal)
                }
                for deviceLang in Locale.preferredLanguages {
                    if let exact = tracks.first(where: { $0.languageCode == deviceLang }) { return exact }
                    let base = deviceLang.components(separatedBy: "-").first ?? deviceLang
                    if let match = tracks.first(where: { $0.languageCode.hasPrefix(base) }) { return match }
                }
                if let original = tracks.first(where: \.isOriginal) { return original }
                let englishPrefixes = ["en-", "en_"]
                if let english = tracks.first(where: { $0.languageCode == "en" })
                    ?? tracks.first(where: { lang in englishPrefixes.contains(where: { lang.languageCode.hasPrefix($0) }) }) {
                    return english
                }
                return tracks.first
            }()
            self.selectedAudioTrack = autoSelect
            if let autoSelect, let option = optionMap[autoSelect.id] {
                item.select(option, in: group)
            }
            playerLog.notice("Audio tracks: \(tracks.map(\.name).joined(separator: ", ")) — auto-selected: \(autoSelect?.name ?? "default")")
        }
    }
}
