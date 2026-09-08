import Foundation
import SwiftUI

// MARK: - AppSettings

/// Persisted app-wide preferences (mirrors Android `PlayerData`, `MainUIData`, `GeneralData`, etc.).
public struct AppSettings: Codable {
    // MARK: Player
    public var preferredQuality: VideoQuality
    public var playbackSpeed: Double
    public var autoplayEnabled: Bool
    public var subtitlesLanguage: String?
    public var backgroundPlaybackEnabled: Bool
    /// When `true`, the player automatically rotates to landscape when a video starts on iPhone.
    public var landscapeAlwaysPlay: Bool
    /// When `true`, Picture-in-Picture is available and the PiP button is shown in the player.
    public var pipEnabled: Bool
    /// When `true` (default), pressing back or swiping down minimizes the player to the
    /// in-app mini-player bar instead of stopping playback. When `false`, the player is
    /// dismissed and playback stops — mirrors the behaviour of a standalone player app.
    public var miniPlayerEnabled: Bool
    /// Seconds to seek backward (configurable; default 10 mirrors Android's default).
    public var seekBackSeconds: Int
    /// Seconds to seek forward (configurable; default 30 mirrors Android's default).
    public var seekForwardSeconds: Int
    /// Seconds before the player controls auto-hide after the last interaction.
    /// Mirrors Android's `PlayerData.controlsHideTimeoutMs`. Default: 4.
    public var controlsHideTimeout: Int

    /// Whether the video should fill the screen (cropping sides) or fit within bounds.
    public enum VideoGravityMode: String, Codable, CaseIterable, Sendable {
        case fit  = "fit"   // resizeAspect — letterbox/pillarbox
        case fill = "fill"  // resizeAspectFill — crops to fill
    }
    public var videoGravityMode: VideoGravityMode

    /// When `true`, the current video replays from the start instead of advancing.
    public var loopEnabled: Bool
    /// When `true`, autoplay picks a random video from the related-videos list.
    public var shuffleEnabled: Bool
    /// When `true`, playing from the Current Queue picks a random remaining video instead of the next sequential one.
    /// Independent from `shuffleEnabled` (which shuffles YouTube recommendations after non-queue playback).
    public var queueShuffleEnabled: Bool

    // MARK: UI
    public var defaultSection: String
    public var compactThumbnails: Bool
    /// Shared compact-card preference for Search, Media Library, and Downloads.
    public var compactSearchCards: Bool
    /// Legacy persisted compatibility field. Production layout reads
    /// `compactSearchCards` as its single source of truth.
    public var compactMediaLibraryCards: Bool
    /// Strict explicit-search filter backed by YouTube audio/caption metadata.
    public var russianOnlySearchEnabled: Bool
    public var oscilloscopeEnabled: Bool
    public var hideShorts: Bool
    /// User-facing positive form of the persisted legacy `hideShorts` flag.
    /// Keeping the stored key preserves existing settings compatibility.
    public var showShorts: Bool {
        get { !hideShorts }
        set { hideShorts = !newValue }
    }
    public var hideLiveShorts: Bool
    public var hideVideoPremieres: Bool
    /// When `true` (default), a per-device `visitorData` token is included in home-feed
    /// requests so YouTube tailors recommendations to this device.
    /// When `false`, the token is cleared and YouTube returns its default shared feed.
    public var perDeviceRecommendationsEnabled: Bool
    public var themeName: ThemeName
    /// Ordered list of section types visible in the sidebar/tab bar.
    /// When empty, all default sections are shown.
    public var enabledSections: [BrowseSection.SectionType]

    // MARK: General

    /// Controls whether watch history is recorded locally and fetched from YouTube.
    /// Mirrors Android's `GeneralData.historyEnabled`.
    public enum HistoryState: String, Codable, CaseIterable, Sendable {
        /// Default — history is fetched from YouTube and local positions are saved.
        case enabled  = "enabled"
        /// History section shows nothing and local watch positions are not saved.
        case disabled = "disabled"
    }
    public var historyState: HistoryState

    // MARK: SponsorBlock

    /// Per-segment action that controls how each SponsorBlock category is handled.
    /// Mirrors Android's per-category action setting in `SponsorBlockData`.
    public enum SponsorBlockAction: String, Codable, CaseIterable, Sendable {
        /// Automatically skip the segment without user interaction.
        case skip      = "skip"
        /// Show a dismissible toast and let the user manually skip.
        case showToast = "showToast"
        /// Take no action — segment plays through normally.
        case nothing   = "nothing"
    }

    public var sponsorBlockEnabled: Bool
    /// Per-category action. Categories absent from this dict are treated as `.nothing`.
    public var sponsorBlockActions: [SponsorSegment.Category: SponsorBlockAction]
    /// Minimum segment length (seconds). Segments shorter than this value are ignored.
    /// 0 means "accept all" (no filtering). Mirrors Android's `SponsorBlockData.minSegmentDuration`.
    public var sponsorBlockMinSegmentDuration: Double
    /// Channels where SponsorBlock is disabled. Key = channelId, value = display title.
    /// Mirrors Android's `SponsorBlockData.excludedChannels`.
    public var sponsorBlockExcludedChannels: [String: String]
    /// Channels hidden from the feed via "Don't Recommend Channel". Key = channelId, value = channel title.
    /// Persists across sessions and syncs via iCloud when `iCloudSyncEnabled` is true.
    public var blockedChannels: [String: String]

    /// Convenience: the set of categories whose action is not `.nothing`.
    /// Passed to `SponsorBlockService.fetchSegments` so we only fetch relevant segments.
    public var activeSponsorCategories: Set<SponsorSegment.Category> {
        Set(sponsorBlockActions.compactMap { $0.value != .nothing ? $0.key : nil })
    }

    /// Returns the action for a given category (`.nothing` if not configured).
    public func sponsorAction(for category: SponsorSegment.Category) -> SponsorBlockAction {
        sponsorBlockActions[category] ?? .nothing
    }

    // MARK: Audio
    /// BCP 47 language code of the user's preferred audio track (e.g. "es", "fr", "pt-BR").
    /// `nil` means use the HLS default. Set implicitly when the user picks a track in the player.
    public var preferredAudioLanguage: String?

    /// BCP 47 language code of the user's last selected caption track (e.g. "en", "es").
    /// `nil` means captions are off. Set implicitly when the user picks a caption track in the player.
    /// Applied automatically to each new video on load.
    public var preferredCaptionLanguage: String?
    /// Automatically creates an on-device transcript from the already saved audio
    /// when YouTube does not provide timed captions.
    public var autoGenerateLocalTranscripts: Bool

    // MARK: DeArrow
    public var deArrowEnabled: Bool

    // MARK: Network
    /// Optional URL of a self-hosted poToken microservice (e.g. youtube-trusted-session-generator).
    /// When set, `ServerPoTokenProvider` is wired up to `InnerTubeAPI` so poToken is injected
    /// into every `/player` request. Nil by default — no token is sent until the user configures
    /// a server URL (see docs/potoken.md §Step 5).
    public var poTokenServiceURL: URL?

    // MARK: Audio-only mode
    /// When `true`, videos load only the audio stream and display the thumbnail.
    /// ~90% data reduction vs 1080p. Live streams are excluded automatically.
    public var audioOnlyMode: Bool

    // MARK: Offline collection
    public enum OfflineAutoSaveMode: String, Codable, CaseIterable, Sendable {
        case off
        case audio
        case video
    }
    /// Automatic internal saving starts once playback begins. Disabled by default.
    public var offlineAutoSaveMode: OfflineAutoSaveMode
    /// Hard collection ceiling in MiB. New saves fail clearly instead of silently
    /// evicting items or filling the device.
    public var offlineStorageLimitMB: Int
    /// When enabled, progressive audio downloads wait for an unmetered Wi-Fi path.
    public var downloadsWiFiOnly: Bool
    /// Opt-in constrained-network mode. Audio-first playback and offline audio
    /// choose the smallest natively playable representation to minimize startup
    /// bytes and make progress on very slow links.
    public var lowBandwidthAudioMode: Bool

    // MARK: Codec preference
    /// When `true`, restricts adaptive video format selection to H.264 (`avc1`) only.
    /// Mirrors Android's `limitVideoCodec("avc1")` opt-in for devices with VP9/AV1
    /// decoder issues. Defaults to `false` (all codecs allowed).
    public var preferH264: Bool

    // MARK: iCloud sync
    /// When `true`, local user data (subscriptions, RSS feeds, video state, queue) is
    /// synced to iCloud via `NSUbiquitousKeyValueStore`. Defaults to `false` (opt-in).
    public var iCloudSyncEnabled: Bool

    // MARK: Experimental (macOS / iOS)
    /// When `true` on macOS, the YouTube IFrame-based TOS-compliant player is used
    /// instead of the AVPlayer-based pipeline. Ads will play. Quality control is unavailable.
    /// Opt-in experiment — has no effect on tvOS.
    public var useTOSPlayerOnMac: Bool
    /// Enables local EDR-capable press pulses on selected dark-mode controls.
    /// Unsupported displays and Simulator use a restrained SDR outline fallback.
    public var experimentalEDRPressGlowEnabled: Bool
    /// Legacy persisted playback Live Activity experiment. Production policy
    /// disables every value so playback has one system Now Playing surface.
    public var dynamicIslandMode: PlaybackLiveActivityMode

    // Note: there is no user-facing `useTOSPlayerOnIOS` setting. iOS uses the
    // native AVPlayer pipeline by default because WKWebView media is suspended by
    // iOS when the device locks and therefore cannot satisfy background-audio or
    // Lock Screen control requirements. The TOS player remains available to its
    // targeted UI tests through SettingsStore.useTOSPlayerOnIOS.

    // MARK: Schema version
    /// Persisted schema version. Version 2 enables background playback by default.
    /// Old JSON lacking this key decodes as 0, signalling a pre-migration store.
    /// Increment when a breaking schema change requires a migration step.
    public var settingsVersion: Int

    // MARK: Types

    /// Canonical ordered list of selectable playback speeds — single source of truth.
    public static let availableSpeeds: [Double] = [0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0]

    /// Canonical ordered list of selectable seek-interval values (seconds) — used by Stepper on iOS and Picker on tvOS.
    public static let availableSeekOptions: [Int] = [5, 10, 15, 20, 30, 45, 60]

    public enum VideoQuality: String, Codable, CaseIterable, Sendable {
        case auto  = "auto"
        case q2160 = "2160p"
        case q1440 = "1440p"
        case q1080 = "1080p"
        case q720  = "720p"
        case q480  = "480p"
        case q360  = "360p"
        case q240  = "240p"
        case q144  = "144p"

        /// The maximum pixel height corresponding to this quality level.
        /// Returns `nil` for `.auto` (no cap).
        public var maxHeight: Int? {
            switch self {
            case .auto:  return nil
            case .q144:  return 144
            case .q240:  return 240
            case .q360:  return 360
            case .q480:  return 480
            case .q720:  return 720
            case .q1080: return 1080
            case .q1440: return 1440
            case .q2160: return 2160
            }
        }

        /// Returns the `VideoQuality` matching an exact pixel height, or `nil` if none matches.
        public static func from(height: Int) -> VideoQuality? {
            allCases.first { $0.maxHeight == height }
        }
    }

    /// Complete user-facing visual themes. Light/dark is an implementation
    /// detail of each design rather than a second, conflicting preference.
    public enum ThemeName: String, Codable, CaseIterable, Sendable {
        case matrix            = "Matrix"
        case monochrome        = "Monochrome"
        case timeline          = "Timeline"
        case colorWashDark     = "ColorWashDark"
        case colorWashLight    = "ColorWashLight"
        case spatialDeck       = "SpatialDeck"
        case livingPoster      = "LivingPoster"
        case signalMap         = "SignalMap"
        case prismRooms        = "PrismRooms"

        public var colorScheme: ColorScheme? {
            switch self {
            case .matrix, .colorWashDark, .spatialDeck, .livingPoster, .prismRooms:
                return .dark
            case .monochrome, .timeline, .colorWashLight, .signalMap:
                return .light
            }
        }

        public var displayName: String {
            switch self {
            case .matrix:         return "Матрица"
            case .monochrome:     return "Монохром"
            case .timeline:       return "Хронология"
            case .colorWashDark:  return "Сияние, ночь"
            case .colorWashLight: return "Сияние, день"
            case .spatialDeck:    return "Орбита"
            case .livingPoster:   return "Живой постер"
            case .signalMap:      return "Сигнал"
            case .prismRooms:     return "Призма"
            }
        }

        public var displaySummary: String {
            switch self {
            case .matrix:         return "Чёрный фон и мягко-зелёные монохромные превью"
            case .monochrome:     return "Светлая типографическая лента с зелёным оттенком"
            case .timeline:       return "Публикации выстроены по времени"
            case .colorWashDark:  return "Тёмный фон подхватывает цвета каждого ролика"
            case .colorWashLight: return "Светлый фон подхватывает цвета каждого ролика"
            case .spatialDeck:    return "Объёмная лента с холодным неоновым светом"
            case .livingPoster:   return "Видео превращаются в крупные кинопостеры"
            case .signalMap:      return "Смелая информационная карта с цветовыми метками"
            case .prismRooms:     return "Насыщенные стеклянные блоки и спектральный свет"
            }
        }

        public var usesMonochromeThumbnails: Bool {
            self == .matrix || self == .monochrome
        }

        public var usesTimelineLayout: Bool { self == .timeline }

        public var usesColorWash: Bool {
            self == .colorWashDark || self == .colorWashLight
        }

        public var usesSpatialDeckLayout: Bool { self == .spatialDeck }
        public var usesPosterLayout: Bool { self == .livingPoster }
        public var usesSignalMapLayout: Bool { self == .signalMap }
        public var usesPrismLayout: Bool { self == .prismRooms }

        /// Reads both the new themes and the retired System/Light/Dark values.
        /// This keeps every other persisted setting intact during the replacement.
        public static func migrated(rawValue: String) -> Self? {
            if let current = Self(rawValue: rawValue) { return current }
            switch rawValue {
            case "Dark":   return .matrix
            case "Light":  return .colorWashLight
            case "System": return .matrix
            default:       return nil
            }
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let rawValue = try container.decode(String.self)
            self = Self.migrated(rawValue: rawValue) ?? .matrix
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
    }

    // MARK: Defaults

    public init() {
        preferredQuality     = .auto
        playbackSpeed        = 1.0
        autoplayEnabled      = true
        subtitlesLanguage    = nil
        backgroundPlaybackEnabled = true
        landscapeAlwaysPlay  = false
        pipEnabled           = true
        miniPlayerEnabled    = true
        seekBackSeconds      = 10
        seekForwardSeconds   = 30
        controlsHideTimeout  = 4
        videoGravityMode     = .fit
        loopEnabled          = false
        shuffleEnabled       = false
        queueShuffleEnabled  = false
        defaultSection       = BrowseSection.SectionType.home.rawValue
        compactThumbnails    = false
        compactSearchCards   = true
        compactMediaLibraryCards = true
        russianOnlySearchEnabled = true
        oscilloscopeEnabled = false
        hideShorts           = true
        hideLiveShorts       = false
        hideVideoPremieres   = false
        perDeviceRecommendationsEnabled = true
        themeName            = .matrix
        enabledSections      = BrowseSection.defaultSections.map(\.type)
        historyState         = .enabled
        sponsorBlockEnabled  = true
        // Default actions mirror Android's SponsorBlockData defaults:
        //   sponsor / selfPromo → auto-skip; interaction / intro / preview / musicOfftopic → show toast; others → nothing
        sponsorBlockActions = [
            .sponsor:       .skip,
            .selfPromo:     .skip,
            .interaction:   .showToast,
            .intro:         .showToast,
            .outro:         .nothing,
            .preview:       .showToast,
            .filler:        .nothing,
            .musicOfftopic: .showToast,
            .poiHighlight:  .nothing,
        ]
        sponsorBlockMinSegmentDuration = 0
        sponsorBlockExcludedChannels   = [:]
        blockedChannels                = [:]
        preferredAudioLanguage = nil
        preferredCaptionLanguage = nil
        autoGenerateLocalTranscripts = false
        deArrowEnabled       = false
        poTokenServiceURL    = nil
        audioOnlyMode        = false
        offlineAutoSaveMode  = .off
        offlineStorageLimitMB = 4096
        downloadsWiFiOnly     = false
        lowBandwidthAudioMode = false
        preferH264           = false
        iCloudSyncEnabled    = false
        #if os(macOS)
        useTOSPlayerOnMac    = true
        #else
        useTOSPlayerOnMac    = false
        #endif
        experimentalEDRPressGlowEnabled = true
        dynamicIslandMode     = .off
        settingsVersion      = 5
    }
}

// MARK: - Forward-compatible Codable

// The synthesized init(from:) requires ALL non-Optional properties to be present in the
// stored JSON. If any property is added, renamed, or type-changed in a new app version,
// the decode throws and SettingsStore silently resets all settings to defaults (bug #181).
//
// This custom init(from:) uses decodeIfPresent with per-field defaults so that:
//  - New fields get their default value when absent from old JSON (forward compatibility).
//  - Renamed/type-changed fields fall back to defaults rather than wiping everything.
//  - settingsVersion = 0 in old JSON signals a pre-migration store for future use.

private extension KeyedDecodingContainer {
    /// Decodes T if the key exists and the value is the right type; returns `defaultValue`
    /// for absent keys, null values, or type mismatches — never throws.
    func safeDecode<T: Decodable>(_ type: T.Type, forKey key: Key, default defaultValue: T) -> T {
        (try? decodeIfPresent(T.self, forKey: key)) ?? defaultValue
    }
}

extension AppSettings {
    // Explicit CodingKeys keep JSON key names stable even if Swift property names change.
    enum CodingKeys: String, CodingKey {
        case settingsVersion
        case preferredQuality
        case playbackSpeed
        case autoplayEnabled
        case subtitlesLanguage
        case backgroundPlaybackEnabled
        case landscapeAlwaysPlay
        case pipEnabled
        case miniPlayerEnabled
        case seekBackSeconds
        case seekForwardSeconds
        case controlsHideTimeout
        case videoGravityMode
        case loopEnabled
        case shuffleEnabled
        case queueShuffleEnabled
        case defaultSection
        case compactThumbnails
        case compactSearchCards
        case compactMediaLibraryCards
        case russianOnlySearchEnabled
        case oscilloscopeEnabled
        case hideShorts
        case hideLiveShorts
        case hideVideoPremieres
        case perDeviceRecommendationsEnabled
        case themeName
        case enabledSections
        case historyState
        case sponsorBlockEnabled
        case sponsorBlockActions
        case sponsorBlockMinSegmentDuration
        case sponsorBlockExcludedChannels
        case blockedChannels
        case preferredAudioLanguage
        case preferredCaptionLanguage
        case autoGenerateLocalTranscripts
        case deArrowEnabled
        case poTokenServiceURL
        case audioOnlyMode
        case offlineAutoSaveMode
        case offlineStorageLimitMB
        case downloadsWiFiOnly
        case lowBandwidthAudioMode
        case preferH264
        case iCloudSyncEnabled
        case useTOSPlayerOnMac
        case experimentalEDRPressGlowEnabled
        case dynamicIslandMode
    }

    public init(from decoder: Decoder) throws {
        let d = AppSettings()   // defaults for any missing/mismatched field
        let c = try decoder.container(keyedBy: CodingKeys.self)
        settingsVersion              = c.safeDecode(Int.self,               forKey: .settingsVersion,              default: 0)
        preferredQuality             = c.safeDecode(VideoQuality.self,      forKey: .preferredQuality,             default: d.preferredQuality)
        playbackSpeed                = c.safeDecode(Double.self,            forKey: .playbackSpeed,                default: d.playbackSpeed)
        autoplayEnabled              = c.safeDecode(Bool.self,              forKey: .autoplayEnabled,              default: d.autoplayEnabled)
        subtitlesLanguage            = c.safeDecode(String?.self,           forKey: .subtitlesLanguage,            default: d.subtitlesLanguage)
        backgroundPlaybackEnabled    = c.safeDecode(Bool.self,              forKey: .backgroundPlaybackEnabled,    default: d.backgroundPlaybackEnabled)
        landscapeAlwaysPlay          = c.safeDecode(Bool.self,              forKey: .landscapeAlwaysPlay,          default: d.landscapeAlwaysPlay)
        pipEnabled                   = c.safeDecode(Bool.self,              forKey: .pipEnabled,                   default: d.pipEnabled)
        miniPlayerEnabled            = c.safeDecode(Bool.self,              forKey: .miniPlayerEnabled,            default: d.miniPlayerEnabled)
        seekBackSeconds              = c.safeDecode(Int.self,               forKey: .seekBackSeconds,              default: d.seekBackSeconds)
        seekForwardSeconds           = c.safeDecode(Int.self,               forKey: .seekForwardSeconds,           default: d.seekForwardSeconds)
        controlsHideTimeout          = c.safeDecode(Int.self,               forKey: .controlsHideTimeout,         default: d.controlsHideTimeout)
        videoGravityMode             = c.safeDecode(VideoGravityMode.self,  forKey: .videoGravityMode,             default: d.videoGravityMode)
        loopEnabled                  = c.safeDecode(Bool.self,              forKey: .loopEnabled,                  default: d.loopEnabled)
        shuffleEnabled               = c.safeDecode(Bool.self,              forKey: .shuffleEnabled,               default: d.shuffleEnabled)
        queueShuffleEnabled          = c.safeDecode(Bool.self,              forKey: .queueShuffleEnabled,          default: d.queueShuffleEnabled)
        defaultSection               = c.safeDecode(String.self,            forKey: .defaultSection,               default: d.defaultSection)
        compactThumbnails            = c.safeDecode(Bool.self,              forKey: .compactThumbnails,            default: d.compactThumbnails)
        compactSearchCards           = c.safeDecode(Bool.self,              forKey: .compactSearchCards,           default: d.compactSearchCards)
        compactMediaLibraryCards     = c.safeDecode(Bool.self,              forKey: .compactMediaLibraryCards,     default: d.compactMediaLibraryCards)
        russianOnlySearchEnabled     = c.safeDecode(Bool.self,              forKey: .russianOnlySearchEnabled,     default: d.russianOnlySearchEnabled)
        oscilloscopeEnabled = c.safeDecode(Bool.self, forKey: .oscilloscopeEnabled, default: false)
        hideShorts                   = c.safeDecode(Bool.self,              forKey: .hideShorts,                   default: d.hideShorts)
        hideLiveShorts               = c.safeDecode(Bool.self,              forKey: .hideLiveShorts,               default: d.hideLiveShorts)
        hideVideoPremieres           = c.safeDecode(Bool.self,              forKey: .hideVideoPremieres,           default: d.hideVideoPremieres)
        perDeviceRecommendationsEnabled = c.safeDecode(Bool.self,           forKey: .perDeviceRecommendationsEnabled, default: d.perDeviceRecommendationsEnabled)
        themeName                    = c.safeDecode(ThemeName.self,         forKey: .themeName,                    default: d.themeName)
        enabledSections              = c.safeDecode([BrowseSection.SectionType].self, forKey: .enabledSections,   default: d.enabledSections)
        historyState                 = c.safeDecode(HistoryState.self,      forKey: .historyState,                 default: d.historyState)
        sponsorBlockEnabled          = c.safeDecode(Bool.self,              forKey: .sponsorBlockEnabled,          default: d.sponsorBlockEnabled)
        sponsorBlockActions          = c.safeDecode([SponsorSegment.Category: SponsorBlockAction].self, forKey: .sponsorBlockActions, default: d.sponsorBlockActions)
        sponsorBlockMinSegmentDuration = c.safeDecode(Double.self,          forKey: .sponsorBlockMinSegmentDuration, default: d.sponsorBlockMinSegmentDuration)
        sponsorBlockExcludedChannels = c.safeDecode([String: String].self,  forKey: .sponsorBlockExcludedChannels, default: d.sponsorBlockExcludedChannels)
        blockedChannels              = c.safeDecode([String: String].self,  forKey: .blockedChannels,              default: d.blockedChannels)
        preferredAudioLanguage       = c.safeDecode(String?.self,           forKey: .preferredAudioLanguage,       default: d.preferredAudioLanguage)
        preferredCaptionLanguage     = c.safeDecode(String?.self,           forKey: .preferredCaptionLanguage,     default: d.preferredCaptionLanguage)
        autoGenerateLocalTranscripts = c.safeDecode(Bool.self,              forKey: .autoGenerateLocalTranscripts, default: d.autoGenerateLocalTranscripts)
        deArrowEnabled               = c.safeDecode(Bool.self,              forKey: .deArrowEnabled,               default: d.deArrowEnabled)
        poTokenServiceURL            = c.safeDecode(URL?.self,              forKey: .poTokenServiceURL,            default: d.poTokenServiceURL)
        audioOnlyMode                = c.safeDecode(Bool.self,              forKey: .audioOnlyMode,                default: d.audioOnlyMode)
        offlineAutoSaveMode          = c.safeDecode(OfflineAutoSaveMode.self, forKey: .offlineAutoSaveMode,       default: d.offlineAutoSaveMode)
        offlineStorageLimitMB        = c.safeDecode(Int.self,               forKey: .offlineStorageLimitMB,        default: d.offlineStorageLimitMB)
        downloadsWiFiOnly            = c.safeDecode(Bool.self,              forKey: .downloadsWiFiOnly,            default: d.downloadsWiFiOnly)
        lowBandwidthAudioMode         = c.safeDecode(Bool.self,              forKey: .lowBandwidthAudioMode,         default: d.lowBandwidthAudioMode)
        preferH264                   = c.safeDecode(Bool.self,              forKey: .preferH264,                   default: d.preferH264)
        iCloudSyncEnabled            = c.safeDecode(Bool.self,              forKey: .iCloudSyncEnabled,            default: d.iCloudSyncEnabled)
        useTOSPlayerOnMac            = c.safeDecode(Bool.self,              forKey: .useTOSPlayerOnMac,            default: d.useTOSPlayerOnMac)
        experimentalEDRPressGlowEnabled = c.safeDecode(Bool.self,           forKey: .experimentalEDRPressGlowEnabled, default: d.experimentalEDRPressGlowEnabled)
        dynamicIslandMode             = c.safeDecode(PlaybackLiveActivityMode.self, forKey: .dynamicIslandMode, default: d.dynamicIslandMode)
    }
}
