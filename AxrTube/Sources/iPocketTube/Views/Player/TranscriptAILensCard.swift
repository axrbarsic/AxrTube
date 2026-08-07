#if os(iOS)
import SwiftUI
import iPocketTubeCore

@MainActor
struct TranscriptAILensCard: View {
    private enum Mode: String, CaseIterable, Identifiable {
        case brief
        case ask
        case connect

        var id: String { rawValue }

        var title: String {
            switch self {
            case .brief: "Обзор"
            case .ask: "Спросить"
            case .connect: "Связать"
            }
        }
    }

    private enum Field: Hashable {
        case question
        case libraryQuery
    }

    @Bindable var manager: TranscriptSummaryManager
    let document: TranscriptBookDocument
    let onSeek: (TimeInterval) -> Void

    @State private var mode: Mode = .brief
    @State private var depth: TranscriptInsightDepth = .quick
    @State private var question = ""
    @State private var libraryQuery = ""
    @FocusState private var focusedField: Field?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            Picker("Режим AI Lens", selection: $mode) {
                ForEach(Mode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("player.aiLens.mode")

            Group {
                switch mode {
                case .brief: briefView
                case .ask: askView
                case .connect: connectView
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(20)
        .iPocketTubeGlassSurface(cornerRadius: 24)
        .task(id: document.cacheKey) {
            manager.prepareIfNeeded(document: document)
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Готово") { focusedField = nil }
            }
        }
        .accessibilityIdentifier("player.aiLens.card")
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles.rectangle.stack.fill")
                .font(.title2)
                .foregroundStyle(.green)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("AxrTube AI Lens")
                    .font(.headline)
                Text("Ответы только по готовой стенограмме")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var briefView: some View {
        VStack(alignment: .leading, spacing: 14) {
            currentSummary
            Divider()
            Text("Объём текста")
                .font(.subheadline.weight(.semibold))
            Picker("Объём текста", selection: $depth) {
                ForEach(TranscriptInsightDepth.allCases, id: \.self) { depth in
                    Text(depth.title).tag(depth)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("player.aiLens.depth")

            Text(depth.explanation)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("player.aiLens.depth.explanation")

            switch manager.briefState {
            case .preparing(let activeDepth) where activeDepth == depth:
                statusRow("Создаём разбор по стенограмме", systemImage: "sparkles")
            case .ready(let brief) where brief.depth == depth:
                Text(brief.text)
                    .font(.body)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("player.aiLens.brief.result")
            case .failed(let message):
                failureView(message) {
                    manager.requestBrief(document: document, depth: depth)
                }
            default:
                Button {
                    focusedField = nil
                    manager.requestBrief(document: document, depth: depth)
                } label: {
                    Label("Создать разбор", systemImage: "text.alignleft")
                        .frame(maxWidth: .infinity, minHeight: 48)
                }
                .iPocketTubeLiquidButtonStyle(prominent: true)
                .accessibilityIdentifier("player.aiLens.brief.generate")
            }
        }
    }

    @ViewBuilder
    private var currentSummary: some View {
        switch manager.state {
        case .ready(let summary):
            VStack(alignment: .leading, spacing: 6) {
                Label("Главная мысль", systemImage: "quote.opening")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(summary.text)
                    .font(.body.weight(.medium))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .preparing:
            statusRow("Уточняем главную мысль", systemImage: "sparkles")
        case .failed:
            if let fallback = TranscriptSummaryPolicy.localMainThought(for: document) {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Локальная выжимка", systemImage: "checkmark.shield")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(fallback)
                        .font(.body.weight(.medium))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        case .needsAPIKey, .idle:
            if let fallback = TranscriptSummaryPolicy.localMainThought(for: document) {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Главная мысль", systemImage: "quote.opening")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(fallback)
                        .font(.body.weight(.medium))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var askView: some View {
        VStack(alignment: .leading, spacing: 14) {
            TextField("Что автор говорит о...", text: $question, axis: .vertical)
                .lineLimit(2...5)
                .textFieldStyle(.roundedBorder)
                .focused($focusedField, equals: .question)
                .submitLabel(.send)
                .onSubmit { submitQuestion() }
                .accessibilityLabel("Вопрос по ролику")
                .accessibilityIdentifier("player.aiLens.ask.field")

            Button(action: submitQuestion) {
                Label("Найти ответ", systemImage: "arrow.up.circle.fill")
                    .frame(maxWidth: .infinity, minHeight: 48)
            }
            .iPocketTubeLiquidButtonStyle(prominent: true)
            .disabled(question.trimmingCharacters(in: .whitespacesAndNewlines).count < 3)
            .accessibilityIdentifier("player.aiLens.ask.submit")

            switch manager.questionState {
            case .idle:
                Text("Ответ появится вместе с фрагментами, на которых он основан.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            case .preparing:
                statusRow("Ищем ответ в стенограмме", systemImage: "text.magnifyingglass")
            case .ready(let answer):
                answerView(answer)
            case .failed(let message):
                failureView(message, retry: submitQuestion)
            }
        }
    }

    private func answerView(_ answer: TranscriptAIAnswer) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(answer.text)
                .font(.body)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("player.aiLens.ask.answer")
            Text("Проверить по стенограмме")
                .font(.subheadline.weight(.semibold))
            ForEach(answer.citations) { citation in
                Button {
                    onSeek(citation.startTime)
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Text(Self.timestamp(citation.startTime))
                            .font(.caption.monospacedDigit().weight(.semibold))
                            .foregroundStyle(.green)
                        Text(citation.text)
                            .font(.footnote)
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.leading)
                            .lineLimit(3)
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Перейти к этому месту в ролике")
            }
        }
    }

    private var connectView: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Найдите мысль во всех сохранённых книгах AxrTube. Поиск выполняется локально.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            TextField("Например: экономия батареи", text: $libraryQuery)
                .textFieldStyle(.roundedBorder)
                .focused($focusedField, equals: .libraryQuery)
                .submitLabel(.search)
                .onSubmit { submitLibrarySearch() }
                .accessibilityLabel("Поиск по сохраненным стенограммам")
                .accessibilityIdentifier("player.aiLens.connect.field")
            Button(action: submitLibrarySearch) {
                Label("Связать с библиотекой", systemImage: "books.vertical.fill")
                    .frame(maxWidth: .infinity, minHeight: 48)
            }
            .iPocketTubeLiquidButtonStyle(prominent: true)
            .disabled(libraryQuery.trimmingCharacters(in: .whitespacesAndNewlines).count < 3)
            .accessibilityIdentifier("player.aiLens.connect.submit")

            switch manager.librarySearchState {
            case .idle:
                EmptyView()
            case .searching:
                statusRow("Ищем в сохранённых книгах", systemImage: "books.vertical")
            case .ready(let matches):
                if matches.isEmpty {
                    Text("В сохранённых стенограммах совпадений не найдено.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(matches) { match in
                        libraryMatch(match)
                    }
                }
            case .failed(let message):
                failureView(message, retry: submitLibrarySearch)
            }
        }
    }

    @ViewBuilder
    private func libraryMatch(_ match: TranscriptLibraryMatch) -> some View {
        let label = VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(Self.timestamp(match.startTime))
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.green)
                Text(match.videoTitle)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
            }
            Text(match.excerpt)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(4)
        }
        .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)

        if match.isCurrentVideo {
            Button { onSeek(match.startTime) } label: { label }
                .buttonStyle(.plain)
        } else if let url = Self.timestampURL(videoID: match.videoID, time: match.startTime) {
            Link(destination: url) { label }
                .buttonStyle(.plain)
        }
    }

    private func statusRow(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Label(title, systemImage: systemImage)
                .font(.subheadline)
        }
        .accessibilityElement(children: .combine)
    }

    private func failureView(_ message: String, retry: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(message, systemImage: "exclamationmark.circle")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Повторить", systemImage: "arrow.clockwise", action: retry)
                .frame(minHeight: 44)
        }
    }

    private func submitQuestion() {
        focusedField = nil
        manager.ask(question: question, document: document)
    }

    private func submitLibrarySearch() {
        focusedField = nil
        manager.searchLibrary(query: libraryQuery, current: document)
    }

    private static func timestamp(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private static func timestampURL(videoID: String, time: TimeInterval) -> URL? {
        var components = URLComponents(string: "https://www.youtube.com/watch")
        components?.queryItems = [
            URLQueryItem(name: "v", value: videoID),
            URLQueryItem(name: "t", value: "\(max(0, Int(time.rounded(.down))))s"),
        ]
        return components?.url
    }
}
#endif
