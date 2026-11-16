#if os(iOS)
import SwiftUI
import iPocketTubeCore

/// iPhone settings laid out like YouTube iOS: a plain grouped list. The
/// "AxrTube" section holds what YouTube does not have: ad blocking,
/// SponsorBlock and the Russian-only filter.
struct YTSettingsView: View {
    @Environment(AuthService.self) private var auth
    @Environment(SettingsStore.self) private var store
    @Environment(DownloadStore.self) private var downloadStore
    @Environment(VideoDownloadService.self) private var downloadService
    @State private var showSignIn = false
    @State private var showSignOutFailure = false
    @State private var showClearDownloads = false
    @State private var streamCacheBytes: Int64 = 0

    var body: some View {
        @Bindable var store = store
        List {
            accountSection

            Section("Общие") {
                Picker("Оформление", selection: $store.settings.appearance) {
                    ForEach(AppSettings.Appearance.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .accessibilityIdentifier("settings.appearance")
                Toggle("Показывать Shorts", isOn: $store.settings.showShorts)
            }

            Section {
                Toggle("Автовоспроизведение", isOn: $store.settings.autoplayEnabled)
                Picker("Качество видео", selection: $store.settings.preferredQuality) {
                    ForEach(AppSettings.VideoQuality.allCases, id: \.self) { quality in
                        Text(quality == .auto ? "Авто" : quality.rawValue).tag(quality)
                    }
                }
                Picker("Скорость по умолчанию", selection: $store.settings.playbackSpeed) {
                    ForEach(AppSettings.availableSpeeds, id: \.self) { speed in
                        Text(speed == 1.0 ? "Обычная" : "\(speed.formatted())×").tag(speed)
                    }
                }
                Toggle("Фоновое воспроизведение", isOn: $store.settings.backgroundPlaybackEnabled)
                Toggle("Картинка в картинке", isOn: $store.settings.pipEnabled)
                Toggle("Только аудио", isOn: $store.settings.audioOnlyMode)
                Toggle("Загружать следующее видео", isOn: $store.settings.prefetchUpNextEnabled)
                    .accessibilityIdentifier("settings.prefetchUpNext")
            } header: {
                Text("Воспроизведение")
            } footer: {
                Text("«Загружать следующее видео»: когда текущий ролик уже в кэше, заранее скачивается первая минута следующего из «Далее» — он начнётся сразу даже на слабой сети.")
            }

            Section {
                Label("Реклама блокируется всегда", systemImage: "checkmark.shield.fill")
                    .foregroundStyle(.green)
                Toggle("Только русские ролики", isOn: $store.settings.russianOnlySearchEnabled)
                    .accessibilityIdentifier("settings.russianOnlySearchToggle")
                NavigationLink("SponsorBlock") { YTSponsorBlockSettingsView() }
                    .accessibilityIdentifier("settings.sponsorBlock")
            } header: {
                Text("AxrTube")
            } footer: {
                Text("«Только русские» действует на главной, в рекомендациях и в поиске.")
            }

            Section("Скачивания") {
                Toggle("Только по Wi-Fi", isOn: $store.settings.downloadsWiFiOnly)
                Picker("Лимит хранилища", selection: $store.settings.offlineStorageLimitMB) {
                    ForEach([1024, 2048, 4096, 8192, 16384], id: \.self) { Text("\($0 / 1024) ГБ").tag($0) }
                }
                Button("Удалить все скачанные", role: .destructive) { showClearDownloads = true }
                    .disabled(downloadStore.entries.isEmpty)
            }

            Section {
                LabeledContent("Кэш просмотра", value: ByteCountFormatter.string(fromByteCount: streamCacheBytes, countStyle: .file))
                Button("Очистить кэш просмотра", role: .destructive) {
                    Task {
                        await HLSCachingProxy.shared.clearCache()
                        streamCacheBytes = await StreamSegmentCache.shared.totalBytes()
                    }
                }
                .disabled(streamCacheBytes == 0)
            } footer: {
                Text("Во время просмотра ролик докачивается целиком, чтобы играть без сети. Старые ролики удаляются сами, кэш не больше 2 ГБ. Ролики, сохранённые кнопкой «Скачать», при очистке не удаляются.")
            }

            Section("Конфиденциальность") {
                Picker("История просмотра", selection: $store.settings.historyState) {
                    Text("Сохранять").tag(AppSettings.HistoryState.enabled)
                    Text("Не сохранять").tag(AppSettings.HistoryState.disabled)
                }
            }

            Section("О приложении") {
                LabeledContent("Версия", value: appVersion)
                if let reportURL = AudioDiagnostics.shared.exportURL {
                    ShareLink("Экспорт журнала воспроизведения", item: reportURL)
                }
                Link("Лицензии", destination: URL(string: "https://github.com/axrbarsic/AxrTube/blob/alex-personal/LICENSE")!)
            }
        }
        .navigationTitle("Настройки")
        .navigationBarTitleDisplayMode(.inline)
        .task { streamCacheBytes = await StreamSegmentCache.shared.totalBytes() }
        .toolbar(.visible, for: .navigationBar)
        .sheet(isPresented: $showSignIn) { SignInView() }
        .alert("Удалить все скачанные видео?", isPresented: $showClearDownloads) {
            Button("Удалить", role: .destructive) {
                downloadService.cancelAll()
                downloadStore.clearAll()
            }
            Button("Отмена", role: .cancel) {}
        }
        .alert("Не удалось выйти", isPresented: $showSignOutFailure) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Данные входа не удалось удалить.")
        }
    }

    @ViewBuilder private var accountSection: some View {
        Section("Аккаунт") {
            if auth.isSignedIn {
                HStack(spacing: 12) {
                    CachedRemoteImage(url: auth.accountAvatarURL) { image in
                        Image(uiImage: image).resizable().scaledToFill()
                    } placeholder: {
                            YTChannelAvatar(title: auth.accountName ?? "?", size: 40)
                    }
                    .frame(width: 40, height: 40)
                    .clipShape(Circle())
                    Text(auth.accountName ?? "Аккаунт")
                }
                Button("Выйти", role: .destructive) {
                    Task { if !(await auth.signOut()) { showSignOutFailure = true } }
                }
            } else {
                Button("Войти в аккаунт") { showSignIn = true }
            }
        }
    }

    private var appVersion: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(v) (\(b))"
    }
}

/// SponsorBlock categories, now reachable on iPhone.
struct YTSponsorBlockSettingsView: View {
    @Environment(SettingsStore.self) private var store

    var body: some View {
        @Bindable var store = store
        List {
            Section {
                Toggle("SponsorBlock", isOn: $store.settings.sponsorBlockEnabled)
                    .accessibilityIdentifier("settings.sponsorBlockToggle")
            } footer: {
                Text("Пропускает спонсорские вставки и другие сегменты, отмеченные сообществом.")
            }
            if store.settings.sponsorBlockEnabled {
                Section("Категории") {
                    ForEach(SponsorSegment.Category.allCases, id: \.self) { category in
                        Picker(selection: Binding(
                            get: { store.settings.sponsorBlockActions[category] ?? .nothing },
                            set: { store.settings.sponsorBlockActions[category] = $0 }
                        )) {
                            Text("Пропускать").tag(AppSettings.SponsorBlockAction.skip)
                            Text("Предлагать").tag(AppSettings.SponsorBlockAction.showToast)
                            Text("Не трогать").tag(AppSettings.SponsorBlockAction.nothing)
                        } label: {
                            HStack(spacing: 8) {
                                Circle().fill(category.color).frame(width: 10, height: 10)
                                Text(Self.title(category))
                            }
                        }
                    }
                }
                Section {
                    Picker("Минимальная длина", selection: $store.settings.sponsorBlockMinSegmentDuration) {
                        Text("Любая").tag(0.0)
                        ForEach([1.0, 2.0, 5.0, 10.0], id: \.self) { Text("\(Int($0)) с").tag($0) }
                    }
                    NavigationLink("Исключённые каналы (\(store.settings.sponsorBlockExcludedChannels.count))") {
                        SponsorBlockExcludedChannelsView()
                    }
                }
            }
        }
        .navigationTitle("SponsorBlock")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
    }

    static func title(_ category: SponsorSegment.Category) -> String {
        switch category {
        case .sponsor: "Спонсор"
        case .selfPromo: "Самореклама"
        case .interaction: "Просьба подписаться"
        case .intro: "Заставка"
        case .outro: "Концовка"
        case .preview: "Анонс"
        case .filler: "Отступление"
        case .musicOfftopic: "Не музыка"
        case .poiHighlight: "Главный момент"
        default: category.displayName
        }
    }
}
#endif
