#if os(iOS)
import Foundation
import Observation
import Security
import iPocketTubeCore

public enum TranscriptSummaryState: Equatable {
    case needsAPIKey
    case idle
    case preparing
    case ready(TranscriptSummary)
    case failed(String)
}

public enum TranscriptAIBriefState: Equatable {
    case idle
    case preparing(TranscriptInsightDepth)
    case ready(TranscriptAIBrief)
    case failed(String)
}

public enum TranscriptAIQuestionState: Equatable {
    case idle
    case preparing
    case ready(TranscriptAIAnswer)
    case failed(String)
}

public enum TranscriptLibrarySearchState: Equatable {
    case idle
    case searching
    case ready([TranscriptLibraryMatch])
    case failed(String)
}

public enum TranscriptSummaryServiceError: Error, LocalizedError {
    case invalidKey(provider: TranscriptAIProvider)
    case insufficientBalance(provider: TranscriptAIProvider)
    case rateLimited(provider: TranscriptAIProvider, retryAfter: TimeInterval)
    case unavailable(provider: TranscriptAIProvider)
    case invalidResponse(provider: TranscriptAIProvider)

    public var errorDescription: String? {
        switch self {
        case .invalidKey(let provider):
            "Ключ \(provider.displayName) не принят. Проверьте его в настройках."
        case .insufficientBalance(let provider):
            "На балансе \(provider.displayName) недостаточно средств. Можно выбрать другой провайдер."
        case .rateLimited(let provider, _):
            "\(provider.displayName) просит немного подождать. Локальный фрагмент уже работает."
        case .unavailable(let provider):
            "\(provider.displayName) сейчас недоступен. Локальный фрагмент уже работает."
        case .invalidResponse(let provider):
            "\(provider.displayName) вернул неподходящий ответ."
        }
    }
}

private enum TranscriptSummaryKeychain {
    static let service = "com.axrtube.transcript-summary"

    static func read(provider: TranscriptAIProvider) -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account(for: provider),
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ value: String?, provider: TranscriptAIProvider) throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account(for: provider),
        ]
        let deleteStatus = SecItemDelete(query as CFDictionary)
        guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else {
            throw TranscriptSummaryServiceError.unavailable(provider: provider)
        }
        guard let value, !value.isEmpty, let data = value.data(using: .utf8) else { return }
        let add: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account(for: provider),
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else {
            throw TranscriptSummaryServiceError.unavailable(provider: provider)
        }
    }

    private static func account(for provider: TranscriptAIProvider) -> String {
        switch provider {
        case .gemini: "gemini-api-key-v1"
        case .deepSeek: "deepseek-api-key-v1"
        case .groq: "groq-api-key-v1"
        }
    }
}

private actor OpenAICompatibleTranscriptSummaryProvider {
    private struct RequestBody: Encodable {
        struct Message: Encodable {
            let role: String
            let content: String
        }
        struct ResponseFormat: Encodable {
            let type: String
        }
        struct Thinking: Encodable {
            let type: String
        }

        let model: String
        let messages: [Message]
        let responseFormat: ResponseFormat
        let temperature: Double
        let maxTokens: Int
        let thinking: Thinking?

        enum CodingKeys: String, CodingKey {
            case model, messages, temperature, thinking
            case responseFormat = "response_format"
            case maxTokens = "max_tokens"
        }
    }

    private struct ResponseBody: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable { let content: String }
            let message: Message
        }
        let choices: [Choice]
    }

    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 45
        configuration.timeoutIntervalForResource = 60
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
    }

    func summarize(
        document: TranscriptBookDocument,
        provider: TranscriptAIProvider,
        modelID: String,
        apiKey: String
    ) async throws -> TranscriptSummary {
        let transcript = TranscriptSummaryPolicy.summaryPromptTranscript(for: document)
        guard !transcript.isEmpty else {
            throw TranscriptSummaryServiceError.invalidResponse(provider: provider)
        }
        let content = try await complete(
            system: "Сожми стенограмму ролика в одно полезное русское предложение. Верни только JSON вида {\"summary\":\"...\"}. Не добавляй вводные слова, рекламу, Markdown и неподтвержденные факты.",
            user: "Название: \(document.metadata.title)\nКанал: \(document.metadata.channelTitle)\nСтенограмма:\n\(transcript)",
            maxCompletionTokens: 220,
            provider: provider,
            modelID: modelID,
            apiKey: apiKey
        )
        guard let contentData = content.data(using: .utf8),
              let clean = TranscriptSummaryPolicy.sanitizedDisplayText(
                try TranscriptSummaryPolicy.decodePayload(contentData).summary
              ) else {
            throw TranscriptSummaryServiceError.invalidResponse(provider: provider)
        }
        return TranscriptSummary(
            cacheKey: TranscriptSummaryPolicy.cacheKey(
                for: document,
                provider: provider,
                modelID: modelID
            ),
            text: clean,
            modelID: modelID
        )
    }

    func brief(
        document: TranscriptBookDocument,
        depth: TranscriptInsightDepth,
        provider: TranscriptAIProvider,
        modelID: String,
        apiKey: String
    ) async throws -> TranscriptAIBrief {
        let transcript = TranscriptSummaryPolicy.promptTranscript(for: document)
        guard !transcript.isEmpty else {
            throw TranscriptSummaryServiceError.invalidResponse(provider: provider)
        }
        let content = try await complete(
            system: "Ты создаешь проверяемый русский разбор только по переданной стенограмме. \(depth.instruction) Верни только JSON вида {\"summary\":\"...\"}. Не выдумывай факты и не добавляй сведения извне.",
            user: "Название: \(document.metadata.title)\nКанал: \(document.metadata.channelTitle)\nСтенограмма:\n\(transcript)",
            maxCompletionTokens: depth == .detailed ? 1_800 : 900,
            provider: provider,
            modelID: modelID,
            apiKey: apiKey
        )
        guard let data = content.data(using: .utf8),
              let text = TranscriptSummaryPolicy.sanitizedLongText(
                try TranscriptSummaryPolicy.decodePayload(data).summary,
                maximumCharacters: depth.maximumCharacters
              ) else {
            throw TranscriptSummaryServiceError.invalidResponse(provider: provider)
        }
        return TranscriptAIBrief(
            cacheKey: TranscriptSummaryPolicy.briefCacheKey(
                for: document,
                depth: depth,
                provider: provider,
                modelID: modelID
            ),
            depth: depth,
            text: text,
            modelID: modelID
        )
    }

    func answer(
        question: String,
        document: TranscriptBookDocument,
        provider: TranscriptAIProvider,
        modelID: String,
        apiKey: String
    ) async throws -> TranscriptAIAnswer {
        let context = TranscriptSummaryPolicy.groundedContext(for: document, question: question)
        guard !context.prompt.isEmpty else {
            throw TranscriptSummaryServiceError.invalidResponse(provider: provider)
        }
        let content = try await complete(
            system: "Ответь на русском языке только по переданным фрагментам стенограммы. Верни только JSON вида {\"answer\":\"...\",\"citations\":[\"p1\",\"p2\"]}. Каждый вывод обязан опираться на существующий идентификатор фрагмента. Если ответа нет, честно скажи об этом и укажи ближайший релевантный фрагмент.",
            user: "Вопрос: \(question)\n\nФрагменты стенограммы:\n\(context.prompt)",
            maxCompletionTokens: 1_000,
            provider: provider,
            modelID: modelID,
            apiKey: apiKey
        )
        guard let data = content.data(using: .utf8),
              let answer = TranscriptSummaryPolicy.validatedAnswer(
                payload: try TranscriptSummaryPolicy.decodeAnswerPayload(data),
                question: question,
                document: document,
                context: context,
                provider: provider,
                modelID: modelID
              ) else {
            throw TranscriptSummaryServiceError.invalidResponse(provider: provider)
        }
        return answer
    }

    private func complete(
        system: String,
        user: String,
        maxCompletionTokens: Int,
        provider: TranscriptAIProvider,
        modelID: String,
        apiKey: String
    ) async throws -> String {
        let url = endpoint(for: provider)
        let body = RequestBody(
            model: modelID,
            messages: [
                .init(role: "system", content: system),
                .init(role: "user", content: user),
            ],
            responseFormat: .init(type: "json_object"),
            temperature: 0.2,
            maxTokens: maxCompletionTokens,
            thinking: provider == .deepSeek ? .init(type: "disabled") : nil
        )
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw TranscriptSummaryServiceError.unavailable(provider: provider)
        }
        switch http.statusCode {
        case 200: break
        case 401, 403: throw TranscriptSummaryServiceError.invalidKey(provider: provider)
        case 402: throw TranscriptSummaryServiceError.insufficientBalance(provider: provider)
        case 429:
            throw TranscriptSummaryServiceError.rateLimited(
                provider: provider,
                retryAfter: TranscriptSummaryPolicy.rateLimitRetryDelay(
                    headerValue: http.value(forHTTPHeaderField: "retry-after")
                )
            )
        case 500...599: throw TranscriptSummaryServiceError.unavailable(provider: provider)
        default: throw TranscriptSummaryServiceError.invalidResponse(provider: provider)
        }
        let responseBody = try JSONDecoder().decode(ResponseBody.self, from: data)
        guard let content = responseBody.choices.first?.message.content, !content.isEmpty else {
            throw TranscriptSummaryServiceError.invalidResponse(provider: provider)
        }
        return content
    }

    private func endpoint(for provider: TranscriptAIProvider) -> URL {
        switch provider {
        case .gemini:
            URL(string: "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions")!
        case .deepSeek:
            URL(string: "https://api.deepseek.com/chat/completions")!
        case .groq:
            URL(string: "https://api.groq.com/openai/v1/chat/completions")!
        }
    }
}

private actor TranscriptBookLibraryReader {
    private struct ManifestEnvelope: Decodable {
        let document: TranscriptBookDocument
    }

    private let directory: URL

    init(directory: URL) {
        self.directory = directory
    }

    func documents(including current: TranscriptBookDocument) -> [TranscriptBookDocument] {
        let fileManager = FileManager.default
        let directories = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        var documents = [current]
        var seen = Set([current.cacheKey])
        for candidate in directories {
            let manifestURL = candidate.appendingPathComponent("manifest.json")
            guard let data = try? Data(contentsOf: manifestURL),
                  let envelope = try? JSONDecoder().decode(ManifestEnvelope.self, from: data),
                  seen.insert(envelope.document.cacheKey).inserted else { continue }
            documents.append(envelope.document)
        }
        return documents
    }
}

@MainActor
@Observable
public final class TranscriptSummaryManager {
    public private(set) var state: TranscriptSummaryState
    public private(set) var briefState: TranscriptAIBriefState = .idle
    public private(set) var questionState: TranscriptAIQuestionState = .idle
    public private(set) var librarySearchState: TranscriptLibrarySearchState = .idle
    public private(set) var selectedProvider: TranscriptAIProvider
    public private(set) var selectedModel: TranscriptAIModelOption
    public private(set) var keyedProviders: Set<TranscriptAIProvider>
    public var hasAPIKey: Bool { keyedProviders.contains(selectedProvider) }
    public private(set) var isShowingLocalFallback = false
    public private(set) var isRateLimited = false
    public private(set) var retryAvailableAt: Date?
    public var onSummaryReady: ((String, String) -> Void)?

    private let provider = OpenAICompatibleTranscriptSummaryProvider()
    private let libraryReader: TranscriptBookLibraryReader
    private var task: Task<Void, Never>?
    private var interactionTask: Task<Void, Never>?
    private var libraryTask: Task<Void, Never>?
    private var activeCacheKey: String?
    private var activeVideoID: String?
    private var pendingDocument: TranscriptBookDocument?
    private let cacheDirectory: URL
    private static let selectedProviderDefaultsKey = "AxrTube.TranscriptAI.SelectedProvider.v1"
    private static let selectedModelDefaultsKey = "AxrTube.TranscriptAI.SelectedModel.v1"

    private static func selectedModelDefaultsKey(for provider: TranscriptAIProvider) -> String {
        "\(selectedModelDefaultsKey).\(provider.rawValue)"
    }

    public init() {
        let availableProviders = Set(TranscriptAIProvider.allCases.filter {
            !(TranscriptSummaryKeychain.read(provider: $0) ?? "").isEmpty
        })
        let defaults = UserDefaults.standard
        let chosenProvider: TranscriptAIProvider
        if let rawProvider = defaults.string(forKey: Self.selectedProviderDefaultsKey),
           let storedProvider = TranscriptAIProvider(rawValue: rawProvider) {
            chosenProvider = storedProvider
        } else if availableProviders.contains(.groq) {
            chosenProvider = .groq
        } else {
            chosenProvider = .gemini
        }
        let chosenModel = TranscriptSummaryPolicy.validatedModel(
            id: defaults.string(forKey: Self.selectedModelDefaultsKey(for: chosenProvider))
                ?? defaults.string(forKey: Self.selectedModelDefaultsKey)
                ?? "",
            provider: chosenProvider
        )
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let summaryDirectory = root
            .appendingPathComponent("AxrTube", isDirectory: true)
            .appendingPathComponent("TranscriptSummaries", isDirectory: true)
        let transcriptLibraryReader = TranscriptBookLibraryReader(directory: root
            .appendingPathComponent("AxrTube", isDirectory: true)
            .appendingPathComponent("TranscriptBooks", isDirectory: true))

        keyedProviders = availableProviders
        selectedProvider = chosenProvider
        selectedModel = chosenModel
        cacheDirectory = summaryDirectory
        libraryReader = transcriptLibraryReader
        state = availableProviders.contains(chosenProvider) ? .idle : .needsAPIKey
    }

    public func hasAPIKey(for provider: TranscriptAIProvider) -> Bool {
        keyedProviders.contains(provider)
    }

    public func selectProvider(_ provider: TranscriptAIProvider) {
        guard provider != selectedProvider else { return }
        selectedProvider = provider
        selectedModel = TranscriptSummaryPolicy.validatedModel(
            id: UserDefaults.standard.string(forKey: Self.selectedModelDefaultsKey(for: provider)) ?? "",
            provider: provider
        )
        persistSelection()
        restartForSelectionChange()
    }

    public func selectModel(id: String) {
        let model = TranscriptSummaryPolicy.validatedModel(id: id, provider: selectedProvider)
        guard model != selectedModel else { return }
        selectedModel = model
        persistSelection()
        restartForSelectionChange()
    }

    public func saveAPIKey(_ value: String, provider: TranscriptAIProvider) throws {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        try TranscriptSummaryKeychain.save(clean.isEmpty ? nil : clean, provider: provider)
        if clean.isEmpty {
            keyedProviders.remove(provider)
        } else {
            keyedProviders.insert(provider)
        }
        activeCacheKey = nil
        isRateLimited = false
        retryAvailableAt = nil
        state = hasAPIKey ? .idle : .needsAPIKey
        if provider == selectedProvider, hasAPIKey, let pendingDocument {
            prepareIfNeeded(document: pendingDocument)
        } else if provider == selectedProvider, !hasAPIKey {
            task?.cancel()
        }
    }

    public func removeAPIKey(provider: TranscriptAIProvider) throws {
        try saveAPIKey("", provider: provider)
    }

    public func prepareIfNeeded(document: TranscriptBookDocument) {
        pendingDocument = document
        let currentProvider = selectedProvider
        let currentModel = selectedModel
        let key = TranscriptSummaryPolicy.cacheKey(
            for: document,
            provider: currentProvider,
            modelID: currentModel.id
        )
        if activeCacheKey == key { return }
        activeCacheKey = key
        activeVideoID = document.metadata.videoID
        task?.cancel()

        if let cached = cachedSummary(key: key) {
            isShowingLocalFallback = false
            isRateLimited = false
            retryAvailableAt = nil
            state = .ready(cached)
            onSummaryReady?(document.metadata.videoID, cached.text)
            return
        }
        if let fallback = TranscriptSummaryPolicy.localFallbackText(for: document) {
            isShowingLocalFallback = true
            onSummaryReady?(document.metadata.videoID, fallback)
        }
        guard let apiKey = TranscriptSummaryKeychain.read(provider: currentProvider), !apiKey.isEmpty else {
            state = .needsAPIKey
            return
        }
        if let retryAvailableAt, retryAvailableAt > Date() {
            isRateLimited = true
            state = .failed("\(currentProvider.displayName) просит немного подождать. Локальный фрагмент уже работает.")
            return
        }
        retryAvailableAt = nil
        state = .preparing
        isRateLimited = false
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let summary = try await provider.summarize(
                    document: document,
                    provider: currentProvider,
                    modelID: currentModel.id,
                    apiKey: apiKey
                )
                guard !Task.isCancelled,
                      activeCacheKey == key,
                      selectedProvider == currentProvider,
                      selectedModel == currentModel,
                      activeVideoID == document.metadata.videoID else { return }
                try persist(summary)
                isShowingLocalFallback = false
                isRateLimited = false
                retryAvailableAt = nil
                state = .ready(summary)
                onSummaryReady?(document.metadata.videoID, summary.text)
            } catch is CancellationError {
                return
            } catch {
                guard activeCacheKey == key else { return }
                if let serviceError = error as? TranscriptSummaryServiceError,
                   case .rateLimited(_, let retryAfter) = serviceError {
                    isRateLimited = true
                    retryAvailableAt = Date().addingTimeInterval(retryAfter)
                } else {
                    isRateLimited = false
                    retryAvailableAt = nil
                }
                state = .failed(error.localizedDescription)
            }
        }
    }

    public func retry() {
        guard let pendingDocument else { return }
        if let retryAvailableAt, retryAvailableAt > Date() {
            isRateLimited = true
            state = .failed("\(selectedProvider.displayName) просит немного подождать. Локальный фрагмент уже работает.")
            return
        }
        retryAvailableAt = nil
        isRateLimited = false
        activeCacheKey = nil
        prepareIfNeeded(document: pendingDocument)
    }

    public func requestBrief(document: TranscriptBookDocument, depth: TranscriptInsightDepth) {
        pendingDocument = document
        interactionTask?.cancel()
        let currentProvider = selectedProvider
        let currentModel = selectedModel
        let key = TranscriptSummaryPolicy.briefCacheKey(
            for: document,
            depth: depth,
            provider: currentProvider,
            modelID: currentModel.id
        )
        if let cached: TranscriptAIBrief = cachedValue(filename: "\(key).json") {
            briefState = .ready(cached)
            return
        }
        guard let apiKey = TranscriptSummaryKeychain.read(provider: currentProvider), !apiKey.isEmpty else {
            briefState = .failed("Добавьте ключ \(currentProvider.displayName) в настройках, чтобы создать разбор.")
            return
        }
        briefState = .preparing(depth)
        interactionTask = Task { [weak self] in
            guard let self else { return }
            do {
                let brief = try await provider.brief(
                    document: document,
                    depth: depth,
                    provider: currentProvider,
                    modelID: currentModel.id,
                    apiKey: apiKey
                )
                guard !Task.isCancelled,
                      selectedProvider == currentProvider,
                      selectedModel == currentModel,
                      pendingDocument?.cacheKey == document.cacheKey else { return }
                try persistValue(brief, filename: "\(brief.cacheKey).json")
                briefState = .ready(brief)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                briefState = .failed(error.localizedDescription)
            }
        }
    }

    public func ask(question: String, document: TranscriptBookDocument) {
        let clean = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count >= 3 else {
            questionState = .failed("Введите вопрос по содержанию ролика.")
            return
        }
        pendingDocument = document
        interactionTask?.cancel()
        let currentProvider = selectedProvider
        let currentModel = selectedModel
        let key = TranscriptSummaryPolicy.questionCacheKey(
            for: document,
            question: clean,
            provider: currentProvider,
            modelID: currentModel.id
        )
        if let cached: TranscriptAIAnswer = cachedValue(filename: "\(key).json") {
            questionState = .ready(cached)
            return
        }
        guard let apiKey = TranscriptSummaryKeychain.read(provider: currentProvider), !apiKey.isEmpty else {
            questionState = .failed("Добавьте ключ \(currentProvider.displayName) в настройках, чтобы задавать вопросы.")
            return
        }
        questionState = .preparing
        interactionTask = Task { [weak self] in
            guard let self else { return }
            do {
                let answer = try await provider.answer(
                    question: clean,
                    document: document,
                    provider: currentProvider,
                    modelID: currentModel.id,
                    apiKey: apiKey
                )
                guard !Task.isCancelled,
                      selectedProvider == currentProvider,
                      selectedModel == currentModel,
                      pendingDocument?.cacheKey == document.cacheKey else { return }
                try persistValue(answer, filename: "\(answer.cacheKey).json")
                questionState = .ready(answer)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                questionState = .failed(error.localizedDescription)
            }
        }
    }

    public func searchLibrary(query: String, current: TranscriptBookDocument) {
        let clean = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count >= 3 else {
            librarySearchState = .ready([])
            return
        }
        libraryTask?.cancel()
        librarySearchState = .searching
        libraryTask = Task { [weak self] in
            guard let self else { return }
            let documents = await libraryReader.documents(including: current)
            guard !Task.isCancelled else { return }
            let matches = TranscriptSummaryPolicy.libraryMatches(
                query: clean,
                documents: documents,
                currentVideoID: current.metadata.videoID
            )
            guard !Task.isCancelled else { return }
            librarySearchState = .ready(matches)
        }
    }

    public func reset(videoID: String? = nil) {
        if let videoID, activeVideoID != videoID { return }
        task?.cancel()
        interactionTask?.cancel()
        libraryTask?.cancel()
        task = nil
        interactionTask = nil
        libraryTask = nil
        activeCacheKey = nil
        activeVideoID = nil
        pendingDocument = nil
        isShowingLocalFallback = false
        isRateLimited = false
        briefState = .idle
        questionState = .idle
        librarySearchState = .idle
        state = hasAPIKey ? .idle : .needsAPIKey
    }

    private func persistSelection() {
        let defaults = UserDefaults.standard
        defaults.set(selectedProvider.rawValue, forKey: Self.selectedProviderDefaultsKey)
        defaults.set(selectedModel.id, forKey: Self.selectedModelDefaultsKey)
        defaults.set(
            selectedModel.id,
            forKey: Self.selectedModelDefaultsKey(for: selectedProvider)
        )
    }

    private func restartForSelectionChange() {
        task?.cancel()
        interactionTask?.cancel()
        activeCacheKey = nil
        isRateLimited = false
        retryAvailableAt = nil
        briefState = .idle
        questionState = .idle
        state = hasAPIKey ? .idle : .needsAPIKey
        if let pendingDocument {
            prepareIfNeeded(document: pendingDocument)
        }
    }

    private func cachedSummary(key: String) -> TranscriptSummary? {
        let url = cacheDirectory.appendingPathComponent("\(key).json")
        guard let data = try? Data(contentsOf: url),
              let summary = try? JSONDecoder().decode(TranscriptSummary.self, from: data),
              summary.cacheKey == key else { return nil }
        return summary
    }

    private func persist(_ summary: TranscriptSummary) throws {
        try FileManager.default.createDirectory(
            at: cacheDirectory,
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(summary)
        try data.write(
            to: cacheDirectory.appendingPathComponent("\(summary.cacheKey).json"),
            options: [.atomic, .completeFileProtectionUnlessOpen]
        )
    }

    private func cachedValue<Value: Decodable>(filename: String) -> Value? {
        let url = cacheDirectory.appendingPathComponent(filename)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Value.self, from: data)
    }

    private func persistValue<Value: Encodable>(_ value: Value, filename: String) throws {
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(
            to: cacheDirectory.appendingPathComponent(filename),
            options: [.atomic, .completeFileProtectionUnlessOpen]
        )
    }
}
#endif
