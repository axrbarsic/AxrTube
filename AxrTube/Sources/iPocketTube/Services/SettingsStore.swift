import Foundation
import Observation
import OSLog
import iPocketTubeCore

private let settingsLog = Logger(subsystem: appSubsystem, category: "Settings")

// MARK: - SettingsStore
//
// Persists `AppSettings` in `UserDefaults` and notifies observers via
// `@Observable`.  Used as an `@Environment` value throughout the app.

@MainActor
@Observable
public final class SettingsStore {

    public var settings: AppSettings {
        didSet {
            if self.settings.hideShorts != oldValue.hideShorts {
                settingsLog.notice("hideShorts \(oldValue.hideShorts ? "ON" : "OFF", privacy: .public) → \(self.settings.hideShorts ? "ON" : "OFF", privacy: .public)")
            }
            self.save()
        }
    }

    /// Whether the YouTube IFrame-based TOS-compliant player is used instead of the
    /// AVPlayer-based pipeline on iOS. The native pipeline is the production default:
    /// unlike WKWebView it can keep an audio session alive while the device is locked,
    /// publish Now Playing metadata, and receive Lock Screen commands. The property is
    /// intentionally non-persisted and remains available for targeted TOS UI tests.
    public var useTOSPlayerOnIOS: Bool = false

    private static let key = "smarttube_app_settings"
    private static let appGroup = "group.com.alexlane.smarttube.local"
    private static let sharedAppearanceKey = "ipockettube_appearance"

    static func migrateToCurrentSchema(_ stored: AppSettings) -> (settings: AppSettings, changed: Bool) {
        var migrated = stored
        var changed = false
        if migrated.settingsVersion < 3 {
            migrated.backgroundPlaybackEnabled = true
            migrated.audioOnlyMode = true
            migrated.autoplayEnabled = false
            migrated.offlineAutoSaveMode = .audio
            changed = true
        }
        if migrated.settingsVersion < 4 {
            // Product default from v4: Shorts are opt-in. This one-time
            // migration also gives existing installs the new default.
            migrated.hideShorts = true
            changed = true
        }
        if migrated.settingsVersion < 5 {
            // Compact cards are the new install/update default. Both historical
            // fields are initialized for decode compatibility; production layout
            // uses compactSearchCards as the single persisted preference.
            migrated.compactSearchCards = true
            migrated.compactMediaLibraryCards = true
            changed = true
        }
        if changed { migrated.settingsVersion = 5 }
        return (migrated, changed)
    }

    public init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            // Version 2 makes background playback part of the default iOS experience.
            // Existing version-1 installs stored the old `false` default, so migrate
            // them once; afterwards the user-facing toggle remains authoritative.
            let migration = Self.migrateToCurrentSchema(decoded)
            if migration.changed {
                if let migrated = try? JSONEncoder().encode(migration.settings) {
                    UserDefaults.standard.set(migrated, forKey: Self.key)
                }
            }
            self.settings = Self.enforcingAudioFirstContract(migration.settings)
        } else {
            self.settings = Self.enforcingAudioFirstContract(AppSettings())
        }
        // Reset settings to defaults when launched for UI testing so each test
        // suite starts from a clean, known state and prior runs cannot bleed in.
        if ProcessInfo.processInfo.arguments.contains("--uitesting-reset-settings") {
            self.settings = AppSettings()
        }
        if ProcessInfo.processInfo.arguments.contains("--uitesting-disable-sponsorblock") {
            self.settings.sponsorBlockEnabled = false
        }
        if ProcessInfo.processInfo.arguments.contains("--uitesting-audio-only-mode") {
            self.settings.audioOnlyMode = true
        }
        if ProcessInfo.processInfo.arguments.contains("--uitesting-hide-shorts") {
            self.settings.hideShorts = true
        }
        if ProcessInfo.processInfo.arguments.contains("--uitesting-enable-tos-player-on-ios") {
            self.useTOSPlayerOnIOS = true
        }
        // Kept for compatibility with existing AVPlayer-specific UI suites.
        if ProcessInfo.processInfo.arguments.contains("--uitesting-disable-tos-player-on-ios") {
            self.useTOSPlayerOnIOS = false
        }
        Self.persistSharedAppearance(settings.themeName)
    }

    private func save() {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
        Self.persistSharedAppearance(settings.themeName)
        iCloudSyncManager.shared.syncEnabled = settings.iCloudSyncEnabled
    }

    private static func persistSharedAppearance(_ appearance: AppSettings.ThemeName) {
        UserDefaults(suiteName: appGroup)?.set(appearance.rawValue, forKey: sharedAppearanceKey)
    }

    public func reset() {
        settings = Self.enforcingAudioFirstContract(AppSettings())
    }

    private static func enforcingAudioFirstContract(_ input: AppSettings) -> AppSettings {
        var result = input
        result.backgroundPlaybackEnabled = true
        result.audioOnlyMode = true
        result.autoplayEnabled = false
        result.offlineAutoSaveMode = .audio
        return result
    }
}
