import SwiftUI
import AuthenticationServices
import iPocketTubeCore

// MARK: - SettingsView
//
// App preferences.  Mirrors the Android settings presenters
// (PlayerData, MainUIData, SponsorBlockData, DeArrowData, AccountsData).

public struct SettingsView: View {
    @Environment(AuthService.self) private var auth
    @Environment(SettingsStore.self) private var store
    @Environment(DownloadStore.self) private var downloadStore
    @State private var showSignIn = false
    @State private var reportSent = false
    @State private var showClearOfflineConfirmation = false
    @State private var showSignOutFailure = false
    #if os(tvOS)
    @State private var showGithubQR = false
    #endif

    public init() {}

    public var body: some View {
        #if os(iOS)
        matrixBody
        #else
        Form {
            accountSection
            audioSection
            offlineSection
            aboutSection
        }
        #if os(macOS)
        .formStyle(.grouped)
        #endif
        .scrollContentBackground(.hidden)
        .iPocketTubeScreenSurface()
        // Hide the blank navigation bar on iOS and tvOS — a visible nav bar on tvOS
        // conflicts with the TabView tab bar scroll-hide animation (issue #102 / gh-34).
        // .navigationBar placement is unavailable on macOS.
        #if !os(macOS)
        .toolbar(.hidden, for: .navigationBar)
        #endif
        #if os(tvOS)
        .sheet(isPresented: $showGithubQR) {
            GitHubQRView()
        }
        #endif
        .alert("Clear Offline Collection", isPresented: $showClearOfflineConfirmation) {
            Button("Clear All", role: .destructive) { downloadStore.clearAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All downloaded video and audio files will be removed from iPocketTube.")
        }
        .alert("Sign Out", isPresented: $showSignOutFailure) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Secure credentials could not be removed. Sign out was not completed.")
        }
        #endif
    }

    #if os(iOS)
    private var matrixBody: some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                iPocketTubeMatrixHeader(title: "Settings")
                    .padding(.horizontal, -iPocketTubeVisualTokens.horizontalPadding)

                iPocketTubeMatrixSection("Account", systemImage: "person.crop.circle") {
                    matrixAccountContent
                }

                iPocketTubeMatrixSection("Theme", systemImage: "circle.lefthalf.filled") {
                    matrixAppearanceContent
                }

                iPocketTubeMatrixSection("Audio", systemImage: "waveform") {
                    matrixAudioContent
                }

                iPocketTubeMatrixSection("Content", systemImage: "rectangle.stack") {
                    matrixContentContent
                }

                iPocketTubeMatrixSection("Always On", systemImage: "checkmark.shield.fill") {
                    Text("No ads • background • pause for external audio")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(iPocketTubeVisualTokens.mintSoft)
                        .fixedSize(horizontal: false, vertical: true)
                }

                iPocketTubeMatrixSection("Diagnostics & About", systemImage: "info.circle") {
                    matrixAboutContent
                }
            }
            .padding(.horizontal, iPocketTubeVisualTokens.horizontalPadding)
            .padding(.bottom, 20)
        }
        .scrollContentBackground(.hidden)
        .iPocketTubeScreenSurface()
        .toolbar(.hidden, for: .navigationBar)
        .alert("Sign Out", isPresented: $showSignOutFailure) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Secure credentials could not be removed. Sign out was not completed.")
        }
    }

    @ViewBuilder private var matrixAccountContent: some View {
        if auth.isSignedIn {
            HStack(spacing: 12) {
                AsyncImage(url: auth.accountAvatarURL) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFill()
                    } else {
                        Circle().fill(iPocketTubeVisualTokens.panelElevated)
                            .overlay(Image(systemName: "person.fill"))
                    }
                }
                .frame(width: 44, height: 44)
                .clipShape(Circle())
                Text(auth.accountName ?? String(localized: "Unknown", bundle: .module))
                    .font(.headline)
                Spacer()
            }
            Divider().overlay(iPocketTubeVisualTokens.stroke)
            Button(role: .destructive) {
                iPocketTubeHaptics.shared.perform(.signOut)
                performSignOut()
            } label: {
                Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }
            .buttonStyle(.plain)
        } else {
            Button {
                iPocketTubeHaptics.shared.perform(.signIn)
                showSignIn = true
            } label: {
                Label("Sign in with Google", systemImage: "person.badge.key")
                    .font(.headline)
                    .foregroundStyle(iPocketTubeVisualTokens.accentForeground)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .background(iPocketTubeVisualTokens.mint, in: RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
            .sheet(isPresented: $showSignIn) { SignInView() }
        }
    }

    private var matrixAppearanceContent: some View {
        @Bindable var store = store
        return Picker("Theme", selection: Binding(
            get: { store.settings.themeName },
            set: { newValue in
                guard newValue != store.settings.themeName else { return }
                iPocketTubeHaptics.shared.perform(.settingsPicker)
                store.settings.themeName = newValue
            }
        )) {
            ForEach(AppSettings.ThemeName.allCases, id: \.self) { theme in
                Text(LocalizedStringKey(theme.rawValue), bundle: .module).tag(theme)
            }
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("settings.themePicker")
    }

    private var matrixAudioContent: some View {
        @Bindable var store = store
        return VStack(spacing: 0) {
            HStack {
                Label("Audio Quality", systemImage: "slider.horizontal.3")
                Spacer()
                Text("Auto")
                    .foregroundStyle(iPocketTubeVisualTokens.mintSoft)
            }
            .frame(minHeight: 44)
            .accessibilityIdentifier("settings.audioQuality")

            Divider().overlay(iPocketTubeVisualTokens.stroke)

            Toggle(isOn: hapticBinding($store.settings.downloadsWiFiOnly)) {
                Label("Wi-Fi Only Downloads", systemImage: "wifi")
            }
            .tint(iPocketTubeVisualTokens.mint)
            .frame(minHeight: 48)
            .accessibilityIdentifier("settings.downloadsWiFiOnly")
        }
    }

    private var matrixContentContent: some View {
        @Bindable var store = store
        return VStack(spacing: 0) {
            Toggle(isOn: hapticBinding($store.settings.compactSearchCards)) {
                VStack(alignment: .leading, spacing: 3) {
                    Label("Compact Search Cards", systemImage: "rectangle.compress.vertical")
                    Text("Half the vertical height")
                        .font(.caption)
                        .foregroundStyle(iPocketTubeVisualTokens.secondaryText)
                }
            }
            .tint(iPocketTubeVisualTokens.mint)
            .frame(minHeight: 56)
            .accessibilityIdentifier("settings.compactSearchCardsToggle")

            Divider().overlay(iPocketTubeVisualTokens.stroke)

            Toggle(isOn: hapticBinding($store.settings.compactMediaLibraryCards)) {
                VStack(alignment: .leading, spacing: 3) {
                    Label("Compact Media Library Cards", systemImage: "rectangle.stack")
                    Text("Half the vertical height")
                        .font(.caption)
                        .foregroundStyle(iPocketTubeVisualTokens.secondaryText)
                }
            }
            .tint(iPocketTubeVisualTokens.mint)
            .frame(minHeight: 56)
            .accessibilityIdentifier("settings.compactMediaLibraryCardsToggle")

            Divider().overlay(iPocketTubeVisualTokens.stroke)

            Toggle(isOn: hapticBinding($store.settings.russianOnlySearchEnabled)) {
                VStack(alignment: .leading, spacing: 3) {
                    Label("Russian-language videos only", systemImage: "waveform.and.mic")
                    Text("Strict search uses available YouTube audio metadata")
                        .font(.caption)
                        .foregroundStyle(iPocketTubeVisualTokens.secondaryText)
                }
            }
            .tint(iPocketTubeVisualTokens.mint)
            .frame(minHeight: 60)
            .accessibilityIdentifier("settings.russianOnlySearchToggle")

            Divider().overlay(iPocketTubeVisualTokens.stroke)

            Toggle(isOn: Binding(
                get: { store.settings.showShorts },
                set: {
                    guard $0 != store.settings.showShorts else { return }
                    iPocketTubeHaptics.shared.perform(.settingsToggle)
                    store.settings.showShorts = $0
                }
            )) {
                VStack(alignment: .leading, spacing: 3) {
                    Label("Show Shorts", systemImage: "rectangle.portrait.on.rectangle.portrait")
                    Text("Shorts appear in video feeds")
                        .font(.caption)
                        .foregroundStyle(iPocketTubeVisualTokens.secondaryText)
                }
            }
            .tint(iPocketTubeVisualTokens.mint)
            .frame(minHeight: 52)
            .accessibilityIdentifier("settings.showShortsToggle")
        }
    }

    private var matrixAboutContent: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Version", systemImage: "app.badge")
                Spacer()
                Text(appVersion).foregroundStyle(iPocketTubeVisualTokens.secondaryText)
            }
            .frame(minHeight: 44)

            Divider().overlay(iPocketTubeVisualTokens.stroke)

            Button {
                CrashlyticsLogger.sendDiagnosticReport()
                reportSent = true
                iPocketTubeHaptics.shared.perform(.operationSucceeded)
            } label: {
                Label(reportSent ? "Report Sent" : "Send Diagnostic Report", systemImage: reportSent ? "checkmark.circle.fill" : "ladybug")
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }
            .buttonStyle(.plain)
            .disabled(reportSent)
            .accessibilityIdentifier("settings.sendDiagnosticReportButton")

            if let reportURL = AudioDiagnostics.shared.exportURL {
                Divider().overlay(iPocketTubeVisualTokens.stroke)

                ShareLink(item: reportURL) {
                    Label("Export Playback Journal", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }
                .accessibilityIdentifier("settings.exportPlaybackJournal")
            }

            Divider().overlay(iPocketTubeVisualTokens.stroke)

            Link(destination: URL(string: "https://github.com/axrbarsic/iPocketTube/blob/alex-personal/LICENSE")!) {
                Label("Licenses", systemImage: "doc.text")
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }
            .accessibilityIdentifier("settings.licensesLink")
        }
    }
    #endif

    // MARK: - Audio-first contract

    private var audioSection: some View {
        @Bindable var store = store
        return Section {
            LabeledContent("Audio Quality", value: String(localized: "Auto", bundle: .module))
                .accessibilityIdentifier("settings.audioQuality")
            Toggle("Wi-Fi Only Downloads", isOn: $store.settings.downloadsWiFiOnly)
                .accessibilityIdentifier("settings.downloadsWiFiOnly")
        } header: {
            Text("Audio")
        } footer: {
            Text("No ads, background playback, and pausing for external audio are always on.")
        }
    }

    // MARK: - Account

    private var accountSection: some View {
        Section("Account") {
            if auth.isSignedIn {
                HStack {
                    #if os(tvOS)
                    let avatarSize: CGFloat = 64
                    #else
                    let avatarSize: CGFloat = 40
                    #endif
                    AsyncImage(url: auth.accountAvatarURL) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().scaledToFill()
                        case .failure, .empty:
                            Circle().fill(Color.secondary.opacity(0.3))
                                .overlay(Image(systemName: "person.fill").foregroundStyle(.secondary))
                        @unknown default:
                            Circle().fill(Color.secondary.opacity(0.3))
                        }
                    }
                    .frame(width: avatarSize, height: avatarSize)
                    .clipShape(Circle())
                    Text(auth.accountName ?? "Unknown")
                }
                Button("Sign Out", role: .destructive) { performSignOut() }
            } else {
                Button("Sign in with Google") { showSignIn = true }
                    .accessibilityIdentifier("settings.signInButton")
                    .sheet(isPresented: $showSignIn) { SignInView() }
            }
        }
    }

    private func performSignOut() {
        Task {
            if !(await auth.signOut()) {
                showSignOutFailure = true
            }
        }
    }

    // MARK: - Player

    private var playerSection: some View {
        @Bindable var store = store
        return Section("Player") {
            Picker("Playback Speed", selection: $store.settings.playbackSpeed) {
                ForEach(AppSettings.availableSpeeds, id: \.self) { s in
                    Text(s == 1.0 ? "Normal" : "\(s, specifier: "%.2g")×").tag(s)
                }
            }

            #if !os(iOS)
            Picker("Max Resolution", selection: $store.settings.preferredQuality) {
                ForEach(AppSettings.VideoQuality.allCases, id: \.self) { q in
                    if q == .auto {
                        Text("Auto").tag(q)
                    } else {
                        Text(verbatim: q.rawValue).tag(q)
                    }
                }
            }
            .accessibilityIdentifier("settings.preferredQualityPicker")

            Picker("Preferred Audio Language", selection: $store.settings.preferredAudioLanguage) {
                Text("System Default").tag(nil as String?)
                Divider()
                Text("English").tag("en" as String?)
                Text("Spanish").tag("es" as String?)
                Text("French").tag("fr" as String?)
                Text("German").tag("de" as String?)
                Text("Japanese").tag("ja" as String?)
                Text("Korean").tag("ko" as String?)
                Text("Portuguese (Brazil)").tag("pt-BR" as String?)
                Text("Chinese (Simplified)").tag("zh-Hans" as String?)
                Divider()
                Text("Original Track Only").tag("original" as String?)
            }
            .accessibilityIdentifier("settings.preferredAudioLanguageRow")
            #endif

            #if os(tvOS)
            Picker("Seek Back", selection: $store.settings.seekBackSeconds) {
                ForEach(AppSettings.availableSeekOptions, id: \.self) { s in
                    Text("\(s) s").tag(s)
                }
            }
            .accessibilityIdentifier("settings.seekBackRow")
            Picker("Seek Forward", selection: $store.settings.seekForwardSeconds) {
                ForEach(AppSettings.availableSeekOptions, id: \.self) { s in
                    Text("\(s) s").tag(s)
                }
            }
            .accessibilityIdentifier("settings.seekForwardRow")
            #elseif os(macOS)
            Stepper(
                "Seek Back: \(store.settings.seekBackSeconds) s",
                value: $store.settings.seekBackSeconds,
                in: 5...60,
                step: 5
            )
            .accessibilityIdentifier("settings.seekBackRow")
            Stepper(
                "Seek Forward: \(store.settings.seekForwardSeconds) s",
                value: $store.settings.seekForwardSeconds,
                in: 5...60,
                step: 5
            )
            .accessibilityIdentifier("settings.seekForwardRow")
            #endif

            #if !os(iOS)
            Picker("Hide Controls After", selection: $store.settings.controlsHideTimeout) {
                Text("2s").tag(2)
                Text("3s").tag(3)
                Text("4s").tag(4)
                Text("5s").tag(5)
                Text("8s").tag(8)
                Text("10s").tag(10)
            }

            Picker("Video Fit", selection: $store.settings.videoGravityMode) {
                Text("Fit (letterbox)").tag(AppSettings.VideoGravityMode.fit)
                Text("Fill (crop)").tag(AppSettings.VideoGravityMode.fill)
            }
            #endif

            Toggle("Loop Video", isOn: $store.settings.loopEnabled)
            Toggle("Shuffle", isOn: $store.settings.shuffleEnabled)

            Toggle("Autoplay next video", isOn: $store.settings.autoplayEnabled)
            Toggle("Background Playback", isOn: $store.settings.backgroundPlaybackEnabled)
            #if !os(iOS)
            Toggle("Prefer H.264 Codec", isOn: $store.settings.preferH264)
                .accessibilityIdentifier("settings.preferH264Toggle")
            #endif
        }
    }

    // MARK: - General

    private var generalSection: some View {
        @Bindable var store = store
        return Section("General") {
            Picker("Watch History", selection: $store.settings.historyState) {
                Text("Enabled").tag(AppSettings.HistoryState.enabled)
                Text("Disabled").tag(AppSettings.HistoryState.disabled)
            }
            Toggle("Sync to iCloud", isOn: $store.settings.iCloudSyncEnabled)
                .accessibilityIdentifier("settings.iCloudSyncToggle")
        }
    }

    // MARK: - Offline collection

    private var offlineSection: some View {
        @Bindable var store = store
        return Section {
            Picker("Storage Limit", selection: $store.settings.offlineStorageLimitMB) {
                Text("1 GB").tag(1024)
                Text("2 GB").tag(2048)
                Text("4 GB").tag(4096)
                Text("8 GB").tag(8192)
                Text("16 GB").tag(16384)
            }
            .accessibilityIdentifier("settings.offlineStorageLimit")

            LabeledContent(
                "Collection Size",
                value: ByteCountFormatter.string(fromByteCount: downloadStore.totalSizeBytes, countStyle: .file)
            )

            if !downloadStore.entries.isEmpty {
                Button("Clear Offline Collection", role: .destructive) {
                    showClearOfflineConfirmation = true
                }
            }
        } header: {
            Text("Offline Collection")
        } footer: {
            Text("Every tapped video is saved as audio. Duplicate items are reused and the storage limit protects the device.")
        }
    }

    // MARK: - UI

    private var uiSection: some View {
        @Bindable var store = store
        return Section("Interface") {
            Picker("Theme", selection: $store.settings.themeName) {
                ForEach(AppSettings.ThemeName.allCases, id: \.self) { t in
                    Text(LocalizedStringKey(t.rawValue), bundle: .module).tag(t)
                }
            }
            .accessibilityIdentifier("settings.themeRow")
            Toggle("Hide Shorts", isOn: $store.settings.hideShorts)
                .accessibilityIdentifier("settings.hideShortsToggle")
            Toggle("Hide Live Shorts", isOn: $store.settings.hideLiveShorts)
                .accessibilityIdentifier("settings.hideLiveShortsToggle")
            Toggle("Hide Video Premieres", isOn: $store.settings.hideVideoPremieres)
                .accessibilityIdentifier("settings.hideVideoPremieresToggle")
            Toggle("Per-Device Recommendations", isOn: $store.settings.perDeviceRecommendationsEnabled)
                .accessibilityIdentifier("settings.perDeviceRecommendationsToggle")
            Toggle("Compact Thumbnails", isOn: $store.settings.compactThumbnails)
            NavigationLink("Visible Sections") {
                SectionsSettingsView()
                    .environment(store)
            }
            .accessibilityIdentifier("settings.visibleSectionsLink")
        }
    }

    // MARK: - SponsorBlock

    private var sponsorBlockSection: some View {
        @Bindable var store = store
        return Section {
            Toggle("Enable SponsorBlock", isOn: $store.settings.sponsorBlockEnabled)
                .accessibilityIdentifier("settings.sponsorBlockToggle")

            if store.settings.sponsorBlockEnabled {
                ForEach(SponsorSegment.Category.allCases, id: \.self) { cat in
                    HStack {
                        Circle()
                            .fill(cat.color)
                            .frame(width: 10, height: 10)
                        Picker(cat.displayName, selection: Binding(
                            get: { store.settings.sponsorBlockActions[cat] ?? .nothing },
                            set: { store.settings.sponsorBlockActions[cat] = $0 }
                        )) {
                            Text("Skip").tag(AppSettings.SponsorBlockAction.skip)
                            Text("Show Toast").tag(AppSettings.SponsorBlockAction.showToast)
                            Text("Nothing").tag(AppSettings.SponsorBlockAction.nothing)
                        }
                        .accessibilityIdentifier("settings.sponsorBlock.\(cat.rawValue)")
                    }
                }

                // Minimum segment duration
                Picker("Min. Segment Length", selection: $store.settings.sponsorBlockMinSegmentDuration) {
                    Text("Off").tag(0.0)
                    Text("1s").tag(1.0)
                    Text("2s").tag(2.0)
                    Text("5s").tag(5.0)
                    Text("10s").tag(10.0)
                }

                // Excluded channels
                NavigationLink("Excluded Channels (\(store.settings.sponsorBlockExcludedChannels.count))") {
                    SponsorBlockExcludedChannelsView()
                }
                .accessibilityIdentifier("settings.sponsorBlockExcludedChannels")
            }
        } header: {
            Text("SponsorBlock")
        } footer: {
            Text("Skip \u{2014} auto-skips. Show Toast \u{2014} shows a skip button. Nothing \u{2014} plays through.")
        }
    }

    // MARK: - DeArrow

    private var deArrowSection: some View {
        @Bindable var store = store
        return Section {
            Toggle("Enable DeArrow", isOn: $store.settings.deArrowEnabled)
        } header: {
            Text("DeArrow")
        } footer: {
            Text("Replace clickbait titles and thumbnails with community-sourced alternatives.")
        }
    }

    // MARK: - Experimental

    #if !os(tvOS)
    private var experimentalSection: some View {
        @Bindable var store = store
        return Section {
            Toggle("EDR Press Glow", isOn: $store.settings.experimentalEDRPressGlowEnabled)
                .accessibilityIdentifier("settings.experimentalEDRPressGlow")
            #if os(macOS)
            Toggle("IFrame Player (TOS-compliant, shows ads)", isOn: $store.settings.useTOSPlayerOnMac)
                .accessibilityIdentifier("settings.useTOSPlayerOnMacToggle")
            #endif
        } header: {
            Text("Experimental")
        } footer: {
            #if os(macOS)
            Text("EDR press glow targets supported displays. The IFrame player uses YouTube's official embedded player; quality selection and downloads are unavailable.")
            #else
            Text("Uses true local EDR headroom on supported displays. Simulator, Low Power Mode, and SDR displays use a restrained fallback.")
            #endif
        }
    }
    #endif

    // MARK: - About

    private var aboutSection: some View {
        Section {
            LabeledContent("Version", value: appVersion)
            #if os(tvOS)
            Button {
                showGithubQR = true
            } label: {
                Label("View on GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
            }
            #else
            Link(destination: URL(string: "https://github.com/axrbarsic/iPocketTube")!) {
                Label("View on GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
            }
            #endif
            Button {
                CrashlyticsLogger.sendDiagnosticReport()
                reportSent = true
            } label: {
                if reportSent {
                    Label("Report Sent", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(iPocketTubeVisualTokens.success)
                } else {
                    Label("Send Diagnostic Report", systemImage: "ladybug")
                }
            }
            .disabled(reportSent)
            .accessibilityIdentifier("settings.sendDiagnosticReportButton")
            Link("Licenses", destination: URL(string: "https://github.com/axrbarsic/iPocketTube/blob/alex-personal/LICENSE")!)
                .accessibilityIdentifier("settings.licensesLink")
        } header: {
            Text("About")
        }
    }

    // MARK: - Helpers

    private var appVersion: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(v) (\(b))"
    }

    private func hapticBinding<Value: Equatable>(_ binding: Binding<Value>) -> Binding<Value> {
        Binding(
            get: { binding.wrappedValue },
            set: { newValue in
                guard newValue != binding.wrappedValue else { return }
                iPocketTubeHaptics.shared.perform(.settingsToggle)
                binding.wrappedValue = newValue
            }
        )
    }
}

// MARK: - GitHubQRView (tvOS)

#if os(tvOS)
private struct GitHubQRView: View {
    @Environment(\.dismiss) private var dismiss

    private let githubURL = "https://github.com/axrbarsic/iPocketTube"

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.opacity(0.85).ignoresSafeArea()

            VStack(spacing: 32) {
                VStack(spacing: 12) {
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                        .font(.system(size: 56))
                        .foregroundStyle(.white)

                    Text("iPocketTube on GitHub")
                        .font(.largeTitle).fontWeight(.bold)

                    Text("Scan the QR code with your phone to view the project on GitHub.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                QRCodeView(content: githubURL)
                    .frame(width: 280, height: 280)
                    .padding(16)
                    .background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 20))

                Text(githubURL)
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .padding(60)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Button {
                dismiss()
            } label: {
                Label("Close", systemImage: "xmark")
                    .font(.headline)
            }
            .padding(40)
        }
    }
}
#endif

// MARK: - SectionsSettingsView

/// Lets the user configure which sections appear in the sidebar / tab bar.
/// Mirrors Android's `MainUIData` section ordering/enabling UI.
struct SectionsSettingsView: View {
    @Environment(SettingsStore.self) private var store

    private let allSections = BrowseSection.allSections

    var body: some View {
        @Bindable var store = store
        List {
            ForEach(allSections) { section in
                Toggle(section.type.localizedTitle, isOn: Binding(
                    get: { store.settings.enabledSections.contains(section.type) },
                    set: { enabled in
                        if enabled {
                            if !store.settings.enabledSections.contains(section.type) {
                                // Insert in canonical order
                                let ordered = allSections
                                    .filter { store.settings.enabledSections.contains($0.type) || $0.type == section.type }
                                    .map { $0.type }
                                store.settings.enabledSections = ordered
                            }
                        } else {
                            // Don't allow disabling the last section
                            if store.settings.enabledSections.count > 1 {
                                store.settings.enabledSections.removeAll { $0 == section.type }
                            }
                        }
                    }
                ))
            }
        }
        .navigationTitle("Visible Sections")
        #if os(iOS)
        .toolbar(.visible, for: .navigationBar)
        #endif
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

// MARK: - SponsorBlockExcludedChannelsView

/// Lists channels excluded from SponsorBlock processing.
/// Channels can be added from ChannelView and removed here via swipe-to-delete.
struct SponsorBlockExcludedChannelsView: View {
    @Environment(SettingsStore.self) private var store

    var body: some View {
        @Bindable var store = store
        let sortedChannels = store.settings.sponsorBlockExcludedChannels
            .sorted { $0.value.localizedCompare($1.value) == .orderedAscending }
        return List {
            if sortedChannels.isEmpty {
                ContentUnavailableView(
                    "No Excluded Channels",
                    systemImage: "person.crop.circle.badge.minus",
                    description: Text("Open a channel and tap \u{201C}Exclude from SponsorBlock\u{201D} to add it here.")
                )
            } else {
                ForEach(sortedChannels, id: \.key) { channelId, title in
                    Text(title)
                }
                .onDelete { indices in
                    let ids = indices.map { sortedChannels[$0].key }
                    ids.forEach { store.settings.sponsorBlockExcludedChannels.removeValue(forKey: $0) }
                }
            }
        }
        .navigationTitle("Excluded Channels")
        #if os(iOS)
        .toolbar(.visible, for: .navigationBar)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            EditButton()
        }
        #endif
    }
}
