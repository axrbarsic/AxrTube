import SwiftUI
import UniformTypeIdentifiers
import iPocketTubeCore

#if os(iOS)
import PDFKit
import UIKit
import WebKit
#endif

#if !os(tvOS)
#if os(iOS)
@MainActor
struct CurrentPlaybackTranscriptPanel: View {
    @Environment(PlayerStateStore.self) private var playerState
    @Environment(PlayerRouter.self) private var playerRouter
    let onDismiss: () -> Void

    private var currentVideo: Video? {
        playerRouter.audioFirst.currentVideo ?? playerState.currentVideo
    }

    var body: some View {
        PlayerTranscriptPanel(
            captions: playerState.vm.captionsManager,
            videoTitle: currentVideo?.title ?? "Текущее видео",
            onSeek: { playerRouter.audioFirst.seek(to: $0) },
            onRetry: { playerState.vm.retryLoad() },
            onDismiss: onDismiss
        )
    }
}
#endif

struct PlayerTranscriptPanel: View {
    private enum Preview: Equatable {
        case adaptive
        case pdf
    }

    @Bindable var captions: CaptionsManager
    #if os(iOS)
    @Environment(PlayerRouter.self) private var playerRouter
    #endif
    let videoTitle: String
    let onSeek: (TimeInterval) -> Void
    let onRetry: () -> Void
    let onDismiss: () -> Void

    @State private var preview: Preview?
    @State private var exportPayload: TranscriptBookExportPayload?
    @State private var isFileExporterPresented = false
    @State private var exportFailureMessage: String?

    private var result: TranscriptBookResult? { captions.transcriptBookResult }

    var body: some View {
        ZStack {
            Color.black.opacity(0.48).ignoresSafeArea()
            NavigationStack {
                Group {
                    #if os(iOS)
                    if preview == .adaptive, let result {
                        HTMLBookPreview(url: result.artifacts.htmlURL)
                            .ignoresSafeArea(edges: .bottom)
                            .accessibilityIdentifier("player.transcriptBook.htmlPreview")
                    } else if preview == .pdf, let result {
                        PDFBookPreview(url: result.artifacts.pdfURL)
                            .ignoresSafeArea(edges: .bottom)
                            .accessibilityIdentifier("player.transcriptBook.pdfPreview")
                    } else {
                        bookContent
                    }
                    #else
                    bookContent
                    #endif
                }
                .navigationTitle(previewTitle)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        if preview != nil {
                            Button("Назад", systemImage: "chevron.backward") {
                                preview = nil
                            }
                            .accessibilityIdentifier("player.transcriptBook.previewBack")
                        } else {
                            Button("Закрыть", systemImage: "xmark", action: onDismiss)
                                .accessibilityIdentifier("player.transcript.close")
                        }
                    }
                    if let preview, let result {
                        ToolbarItem(placement: .primaryAction) {
                            Menu {
                                Button("Сохранить в Файлы", systemImage: "folder.badge.plus") {
                                    beginFileExport(
                                        preview == .adaptive ? .html : .pdf,
                                        result: result
                                    )
                                }
                                ShareLink(item: preview == .adaptive
                                    ? result.artifacts.htmlURL
                                    : result.artifacts.pdfURL) {
                                    Label("Поделиться", systemImage: "square.and.arrow.up")
                                }
                            } label: {
                                Label("Экспорт", systemImage: "square.and.arrow.up")
                            }
                            .accessibilityIdentifier("player.transcriptBook.previewShareToolbar")
                        }
                    }
                }
            }
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .accessibilityIdentifier("player.transcript.panel")
        }
        .fileExporter(
            isPresented: $isFileExporterPresented,
            document: exportPayload.map { TranscriptBookFileDocument(data: $0.data) },
            contentType: exportPayload?.format.contentType ?? .data,
            defaultFilename: exportPayload?.filename ?? "AxrTube"
        ) { result in
            if case .failure = result {
                exportFailureMessage = "Не удалось сохранить файл. Выберите другую папку и повторите попытку."
            }
            exportPayload = nil
        }
        .alert(
            "Не удалось сохранить файл",
            isPresented: Binding(
                get: { exportFailureMessage != nil },
                set: { if !$0 { exportFailureMessage = nil } }
            )
        ) {
            Button("ОК") { exportFailureMessage = nil }
        } message: {
            Text(exportFailureMessage ?? "Повторите попытку.")
        }
    }

    private var previewTitle: String {
        switch preview {
        case .adaptive: "Адаптивная книга"
        case .pdf: "PDF"
        case nil: "Книга стенограммы"
        }
    }

    @ViewBuilder
    private var bookContent: some View {
        ScrollView {
            VStack(spacing: 22) {
                switch captions.transcriptBookState {
                case .collecting:
                    collectingView
                case .ready:
                    if let result { readyCard(result) } else { failedView }
                case .unavailable:
                    unavailableView
                case .failed:
                    failedView
                }
            }
            .frame(maxWidth: 620)
            .padding(.horizontal, 20)
            .padding(.top, 22)
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.visible)
        .background(Color.clear)
    }

    private var collectingView: some View {
        VStack(spacing: 18) {
            Image(systemName: "book.pages")
                .font(.system(size: 46, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.red)
                .accessibilityHidden(true)
            ProgressView()
                .controlSize(.large)
                .accessibilityLabel(collectingTitle)
            VStack(spacing: 6) {
                Text(collectingTitle)
                    .font(.title2.weight(.semibold))
                Text(collectingDetail)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 330)
        .padding(28)
        .iPocketTubeGlassSurface(cornerRadius: 24)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("player.transcriptBook.collecting")
    }

    private var collectingTitle: String {
        switch captions.transcriptState {
        case .translationPreparing:
            "Готовим перевод на русский"
        case .translationCurrentFragment:
            "Переводим текущий фрагмент"
        case .translationAhead:
            "Переводим дальше по ролику"
        case .translationRemaining:
            "Завершаем русскую стенограмму"
        default:
            "Собираем стенограмму"
        }
    }

    private var collectingDetail: String {
        switch captions.transcriptState {
        case .translationPreparing:
            "iPhone подготавливает встроенный системный переводчик. Английский текст не показывается."
        case .translationCurrentFragment, .translationAhead, .translationRemaining:
            "Перевод выполняется на устройстве. Книга появится целиком на русском языке."
        default:
            "Получаем всю дорожку целиком, убираем повторы и оформляем русскую книгу."
        }
    }

    private func readyCard(_ result: TranscriptBookResult) -> some View {
        VStack(spacing: 22) {
            VStack(spacing: 14) {
                Image(systemName: "book.closed.fill")
                    .font(.system(size: 48, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.red)
                    .accessibilityHidden(true)
                VStack(spacing: 7) {
                    Text(videoTitle)
                        .font(.title2.weight(.bold))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Русский · \(result.artifacts.pageCount) стр. · \(result.document.paragraphCount) абз.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    if result.wasCached {
                        Label("Открыто из сохранённой книги", systemImage: "checkmark.icloud")
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                    Text("HTML · PDF · Markdown")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Форматы: адаптивная веб-книга, PDF и Markdown")
                }
            }
            .frame(maxWidth: .infinity)

            #if os(iOS)
            TranscriptAILensCard(
                manager: playerRouter.transcriptSummary,
                document: result.document,
                onSeek: onSeek
            )
            #endif

            VStack(spacing: 12) {
                Button {
                    preview = .adaptive
                } label: {
                    Label("Открыть адаптивную книгу", systemImage: "rectangle.expand.vertical")
                        .frame(maxWidth: .infinity, minHeight: 50)
                }
                .iPocketTubeLiquidButtonStyle(prominent: true)
                .accessibilityHint("Текст подстраивается под ширину экрана и системную тему")
                .accessibilityIdentifier("player.transcriptBook.openHTML")

                Button {
                    preview = .pdf
                } label: {
                    Label("Открыть PDF", systemImage: "doc.richtext")
                        .frame(maxWidth: .infinity, minHeight: 50)
                }
                .iPocketTubeLiquidButtonStyle()
                .accessibilityIdentifier("player.transcriptBook.openPDF")

                Menu {
                    Section("Сохранить в Файлы") {
                        Button("Адаптивная книга HTML", systemImage: "safari") {
                            beginFileExport(.html, result: result)
                        }
                        Button("PDF", systemImage: "doc.richtext") {
                            beginFileExport(.pdf, result: result)
                        }
                        Button("Markdown", systemImage: "doc.text") {
                            beginFileExport(.markdown, result: result)
                        }
                    }
                    Section("Поделиться") {
                        ShareLink(item: result.artifacts.htmlURL) {
                            Label("Адаптивная книга HTML", systemImage: "safari")
                        }
                        ShareLink(item: result.artifacts.pdfURL) {
                            Label("PDF", systemImage: "doc.richtext")
                        }
                        ShareLink(item: result.artifacts.markdownURL) {
                            Label("Markdown", systemImage: "doc.text")
                        }
                    }
                } label: {
                    Label("Сохранить или поделиться", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity, minHeight: 50)
                }
                .iPocketTubeLiquidButtonStyle()
                .accessibilityIdentifier("player.transcriptBook.shareMenu")
            }

            Button("Пересобрать", systemImage: "arrow.clockwise") {
                captions.rebuildTranscriptBook()
            }
            .font(.callout.weight(.medium))
            .frame(minHeight: 44)
            .accessibilityIdentifier("player.transcriptBook.rebuild")
        }
        .padding(24)
        .iPocketTubeGlassSurface(cornerRadius: 24)
        .accessibilityIdentifier("player.transcriptBook.ready")
    }

    private func beginFileExport(
        _ format: TranscriptBookFileFormat,
        result: TranscriptBookResult
    ) {
        do {
            exportPayload = try TranscriptBookFileExportPolicy.payload(
                from: result.artifacts,
                format: format
            )
            isFileExporterPresented = true
        } catch {
            exportFailureMessage = "Файл книги повреждён или недоступен. Пересоберите книгу и повторите попытку."
        }
    }

    private var unavailableView: some View {
        statusView(
            icon: "captions.bubble.fill",
            title: "Стенограмма недоступна",
            detail: "У этого ролика нет русской или английской дорожки субтитров YouTube.",
            retryTitle: "Повторить"
        ) { onRetry() }
    }

    private var failedView: some View {
        if captions.transcriptState == .translationRetryable {
            statusView(
                icon: "arrow.trianglehead.2.clockwise.rotate.90",
                title: "Перевод пока не подготовлен",
                detail: "Подключитесь к сети для первой загрузки системного перевода с английского на русский. После этого перевод работает на устройстве.",
                retryTitle: "Повторить"
            ) { captions.retryRussianTranslation() }
        } else if captions.transcriptState == .translationUnsupported {
            statusView(
                icon: "exclamationmark.triangle.fill",
                title: "Системный перевод недоступен",
                detail: "На этом iPhone языковая пара с английского на русский сейчас не поддерживается.",
                retryTitle: "Проверить снова"
            ) { captions.retryRussianTranslation() }
        } else {
        statusView(
            icon: "exclamationmark.triangle.fill",
            title: "Не удалось собрать книгу",
            detail: "Исходные субтитры не повреждены. Повторите подготовку документа.",
            retryTitle: "Пересобрать"
        ) { captions.rebuildTranscriptBook() }
        }
    }

    private func statusView(
        icon: String,
        title: String,
        detail: String,
        retryTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 42, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(title)
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
            Text(detail)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button(retryTitle, systemImage: "arrow.clockwise", action: action)
                .frame(minWidth: 180, minHeight: 50)
                .iPocketTubeLiquidButtonStyle(prominent: true)
        }
        .frame(maxWidth: .infinity, minHeight: 330)
        .padding(28)
        .iPocketTubeGlassSurface(cornerRadius: 24)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("player.transcriptBook.status")
    }
}

#if os(iOS)
private struct HTMLBookPreview: UIViewRepresentable {
    let url: URL

    final class Coordinator {
        var loadedURL: URL?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        guard context.coordinator.loadedURL != url else { return }
        context.coordinator.loadedURL = url
        guard let html = try? String(contentsOf: url, encoding: .utf8) else {
            view.loadHTMLString(
                "<html><body><p>Не удалось открыть адаптивную книгу.</p></body></html>",
                baseURL: nil
            )
            return
        }
        view.loadHTMLString(html, baseURL: url.deletingLastPathComponent())
    }
}

private struct PDFBookPreview: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.backgroundColor = .systemBackground
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        if view.document?.documentURL != url {
            view.document = PDFDocument(url: url)
        }
    }
}

#if DEBUG
@MainActor
public struct TranscriptBookSmokeView: View {
    @State private var captions: CaptionsManager
    private let languageCode: String

    public init(languageCode: String) {
        let normalizedLanguage = TranscriptBookPolicy.baseLanguage(languageCode) == "en" ? "en" : "ru"
        let fixture = Self.fixture(languageCode: normalizedLanguage)
        let russianFixture = Self.fixture(languageCode: "ru")
        let service = TranscriptBookService()
        _captions = State(initialValue: CaptionsManager(
            cueLoader: { _ in fixture },
            russianTranscriptLoader: { _, progress in
                guard normalizedLanguage == "en" else {
                    throw RussianTranscriptFailure.translationFailed
                }
                progress(.stage(.translatingCurrentFragment))
                progress(.translated(
                    cues: Array(russianFixture.prefix(8)),
                    stage: .translatingCurrentFragment
                ))
                return RussianTranscriptResult(cues: russianFixture, wasCached: false)
            },
            transcriptBookLoader: { request in try await service.prepare(request) }
        ))
        self.languageCode = normalizedLanguage
    }

    public var body: some View {
        PlayerTranscriptPanel(
            captions: captions,
            videoTitle: languageCode == "ru"
                ? "Как проектировать понятные мобильные приложения"
                : "How to design understandable mobile applications",
            onSeek: { _ in },
            onRetry: { start() },
            onDismiss: {}
        )
        .task { start() }
    }

    private func start() {
        let title = languageCode == "ru"
            ? "Как проектировать понятные мобильные приложения"
            : "How to design understandable mobile applications"
        let identity = captions.beginPlaybackItem(
            "transcript-book-smoke-\(languageCode)",
            bookMetadata: TranscriptBookMetadata(
                videoID: "transcript-book-smoke-\(languageCode)",
                title: title,
                channelTitle: languageCode == "ru" ? "Разговоры о разработке" : "Product Engineering Talks",
                duration: 359.5
            )
        )
        let track = CaptionTrack(
            id: "fixture-\(languageCode)",
            baseURL: URL(string: "https://fixture.invalid/\(languageCode).vtt")!,
            name: languageCode == "ru" ? "Русский" : "English",
            languageCode: languageCode,
            isAutoGenerated: false
        )
        _ = captions.applyAvailableCaptions(
            [track],
            for: identity,
            preferredLanguage: nil
        )
    }

    private static func fixture(languageCode: String) -> [CaptionCue] {
        let russianTopics = [
            "Первый запуск знакомит человека с назначением продукта",
            "Навигация показывает доступные разделы и сохраняет контекст",
            "Карточка ролика выделяет название, автора и дату публикации",
            "Экран воспроизведения оставляет главные действия под рукой",
            "Стенограмма превращается в самостоятельный переносимый документ",
            "Системное меню экспорта открывает привычные приложения и Файлы",
            "Светлая и тёмная темы используют одну спокойную иерархию",
            "Проверка на устройстве завершает продуктовый цикл",
        ]
        let russianDetails = [
            "и предлагает понятный следующий шаг без лишних решений.",
            "поэтому возвращение к задаче не требует повторного поиска.",
            "что помогает быстро оценить содержание до открытия.",
            "но вторичные настройки не конкурируют с просмотром.",
            "с аккуратными разделами, ссылками и временными отметками.",
            "без отдельного аккаунта, сервера или закрытого формата.",
            "а системные настройки доступности остаются рабочими.",
            "когда реальный сценарий подтверждён и результат можно сохранить.",
            "при этом кэш ускоряет повторное открытие той же книги.",
        ]
        let englishTopics = [
            "The first launch explains the purpose of the product",
            "Navigation reveals the available sections while preserving context",
            "Each video card emphasizes the title, author, and publication date",
            "The playback screen keeps the primary actions within easy reach",
            "The transcript becomes a complete portable document",
            "The system share menu opens familiar apps and file destinations",
            "Light and dark appearances follow the same calm hierarchy",
            "A device check completes the product development cycle",
        ]
        let englishDetails = [
            "and offers a clear next step without unnecessary decisions.",
            "so returning to the task never requires another search.",
            "which helps people evaluate the content before opening it.",
            "while secondary settings never compete with playback.",
            "with readable chapters, links, and compact time markers.",
            "without a separate account, server, or proprietary format.",
            "and the system accessibility preferences remain effective.",
            "after the real workflow is confirmed and the result can be saved.",
            "while the cache makes the same book open immediately next time.",
        ]
        return (0..<72).map { index in
            let topicIndex = index % 8
            let detailIndex = (index + 2 * (index / 8)) % 9
            let text = languageCode == "ru"
                ? "\(russianTopics[topicIndex]) \(russianDetails[detailIndex])"
                : "\(englishTopics[topicIndex]) \(englishDetails[detailIndex])"
            return CaptionCue(
                startTime: Double(index * 5),
                endTime: Double(index * 5) + 4.5,
                text: text
            )
        }
    }
}
#endif
#endif

private extension TranscriptBookFileFormat {
    var contentType: UTType {
        switch self {
        case .markdown: UTType(filenameExtension: "md") ?? .plainText
        case .html: .html
        case .pdf: .pdf
        }
    }
}

private struct TranscriptBookFileDocument: FileDocument {
    static let readableContentTypes: [UTType] = [
        TranscriptBookFileFormat.markdown.contentType,
        .html,
        .pdf,
    ]

    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw TranscriptBookFailure.exportFailed
        }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
#endif
