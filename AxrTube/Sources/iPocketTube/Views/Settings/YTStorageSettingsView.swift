#if os(iOS)
import SwiftUI
import iPocketTubeCore

/// «Хранилище»: everything the app keeps on the phone in one place — saved
/// videos, the viewing cache and older file downloads — with one cache limit.
struct YTStorageSettingsView: View {
    @Environment(SettingsStore.self) private var store
    @Environment(DownloadStore.self) private var downloadStore
    @Environment(VideoDownloadService.self) private var downloadService
    @State private var library = PinnedStreamLibrary.shared
    @State private var cacheBytes: Int64 = 0
    @State private var confirmCache = false
    @State private var confirmLegacy = false

    static let limits = [1024, 2048, 4096, 8192, 16384]

    var body: some View {
        @Bindable var store = store
        List {
            Section {
                row("Сохранённое", library.totalBytes, icon: "bookmark.fill", tint: YTProgressLayers.cacheColor)
                row("Кэш просмотра", cacheBytes, icon: "clock.arrow.circlepath", tint: .orange)
                if downloadStore.totalSizeBytes > 0 {
                    row("Загрузки прежней версии", downloadStore.totalSizeBytes, icon: "doc", tint: .gray)
                }
            } header: {
                Text("Занято · \(Self.format(library.totalBytes + cacheBytes + downloadStore.totalSizeBytes))")
            }

            Section {
                Picker("Лимит кэша просмотра", selection: $store.settings.offlineStorageLimitMB) {
                    ForEach(Self.limits, id: \.self) { Text("\($0 / 1024) ГБ").tag($0) }
                }
                Button("Очистить кэш просмотра", role: .destructive) { confirmCache = true }
                    .disabled(cacheBytes == 0)
            } footer: {
                Text("Пока ты смотришь, ролик докачивается целиком, чтобы играть без сети. Когда кэш упирается в лимит, первыми удаляются давно просмотренные ролики. На телефоне всегда остаётся не меньше 3 ГБ свободного места. Сохранённое в лимит не входит и само не удаляется.")
            }

            if downloadStore.totalSizeBytes > 0 {
                Section {
                    Button("Удалить загрузки прежней версии", role: .destructive) { confirmLegacy = true }
                } footer: {
                    Text("Файлы, скачанные старой кнопкой «Скачать». Они по-прежнему видны в «Сохранённом».")
                }
            }
        }
        .navigationTitle("Хранилище")
        .navigationBarTitleDisplayMode(.inline)
        .task { cacheBytes = await StreamSegmentCache.shared.totalBytes() }
        .confirmationDialog("Очистить кэш просмотра?", isPresented: $confirmCache, titleVisibility: .visible) {
            Button("Очистить", role: .destructive) {
                Task {
                    await HLSCachingProxy.shared.clearCache()
                    cacheBytes = await StreamSegmentCache.shared.totalBytes()
                }
            }
        }
        .confirmationDialog("Удалить загрузки прежней версии?", isPresented: $confirmLegacy, titleVisibility: .visible) {
            Button("Удалить", role: .destructive) {
                downloadService.cancelAll()
                downloadStore.clearAll()
            }
        }
    }

    private func row(_ title: String, _ bytes: Int64, icon: String, tint: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(tint).frame(width: 24)
            Text(title)
            Spacer()
            Text(Self.format(bytes)).foregroundStyle(.secondary).monospacedDigit()
        }
    }

    static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
#endif
