import Foundation

public struct TranscriptSummary: Codable, Equatable, Sendable {
    public let cacheKey: String
    public let text: String
    public let modelID: String
    public let generatedAt: Date

    public init(cacheKey: String, text: String, modelID: String, generatedAt: Date = Date()) {
        self.cacheKey = cacheKey
        self.text = text
        self.modelID = modelID
        self.generatedAt = generatedAt
    }
}

public struct TranscriptSummaryPayload: Codable, Equatable, Sendable {
    public let summary: String

    public init(summary: String) {
        self.summary = summary
    }
}

public enum TranscriptInsightDepth: String, Codable, CaseIterable, Equatable, Sendable {
    case quick
    case standard
    case detailed

    public var title: String {
        switch self {
        case .quick: "Суть"
        case .standard: "Кратко"
        case .detailed: "Подробно"
        }
    }

    public var explanation: String {
        switch self {
        case .quick: "Один законченный абзац"
        case .standard: "Несколько законченных абзацев"
        case .detailed: "Разбор по разделам"
        }
    }

    public var instruction: String {
        switch self {
        case .quick:
            "Дай суть в одном законченном абзаце. Не обрывай предложение."
        case .standard:
            "Дай краткий разбор в нескольких законченных абзацах. Не обрывай последний абзац."
        case .detailed:
            "Дай подробный разбор по разделам: главная мысль, аргументы, практические выводы и важные ограничения. Каждый раздел должен быть закончен."
        }
    }

    public var maximumCharacters: Int {
        switch self {
        case .quick: 700
        case .standard: 2_000
        case .detailed: 4_500
        }
    }
}

public struct TranscriptAIBrief: Codable, Equatable, Sendable {
    public let cacheKey: String
    public let depth: TranscriptInsightDepth
    public let text: String
    public let modelID: String

    public init(cacheKey: String, depth: TranscriptInsightDepth, text: String, modelID: String) {
        self.cacheKey = cacheKey
        self.depth = depth
        self.text = text
        self.modelID = modelID
    }
}

public struct TranscriptAICitation: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let startTime: TimeInterval
    public let text: String

    public init(id: String, startTime: TimeInterval, text: String) {
        self.id = id
        self.startTime = startTime
        self.text = text
    }
}

public struct TranscriptAIAnswer: Codable, Equatable, Sendable {
    public let cacheKey: String
    public let question: String
    public let text: String
    public let citations: [TranscriptAICitation]
    public let modelID: String

    public init(
        cacheKey: String,
        question: String,
        text: String,
        citations: [TranscriptAICitation],
        modelID: String
    ) {
        self.cacheKey = cacheKey
        self.question = question
        self.text = text
        self.citations = citations
        self.modelID = modelID
    }
}

public struct TranscriptAIAnswerPayload: Codable, Equatable, Sendable {
    public let answer: String
    public let citations: [String]

    public init(answer: String, citations: [String]) {
        self.answer = answer
        self.citations = citations
    }
}

public struct TranscriptGroundedContext: Equatable, Sendable {
    public let prompt: String
    public let citations: [TranscriptAICitation]

    public init(prompt: String, citations: [TranscriptAICitation]) {
        self.prompt = prompt
        self.citations = citations
    }
}

public struct TranscriptLibraryMatch: Equatable, Identifiable, Sendable {
    public let id: String
    public let videoID: String
    public let videoTitle: String
    public let channelTitle: String
    public let startTime: TimeInterval
    public let excerpt: String
    public let isCurrentVideo: Bool

    public init(
        id: String,
        videoID: String,
        videoTitle: String,
        channelTitle: String,
        startTime: TimeInterval,
        excerpt: String,
        isCurrentVideo: Bool
    ) {
        self.id = id
        self.videoID = videoID
        self.videoTitle = videoTitle
        self.channelTitle = channelTitle
        self.startTime = startTime
        self.excerpt = excerpt
        self.isCurrentVideo = isCurrentVideo
    }
}

public enum TranscriptAIProvider: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case gemini
    case deepSeek
    case groq

    public var displayName: String {
        switch self {
        case .gemini: "Gemini"
        case .deepSeek: "DeepSeek"
        case .groq: "Groq"
        }
    }

    public var keyURL: URL {
        switch self {
        case .gemini: URL(string: "https://aistudio.google.com/api-keys")!
        case .deepSeek: URL(string: "https://platform.deepseek.com/api_keys")!
        case .groq: URL(string: "https://console.groq.com/keys")!
        }
    }
}

public struct TranscriptAIModelOption: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let provider: TranscriptAIProvider
    public let displayName: String

    public init(id: String, provider: TranscriptAIProvider, displayName: String) {
        self.id = id
        self.provider = provider
        self.displayName = displayName
    }
}

public enum TranscriptSummaryPolicy {
    public static let schemaVersion = 4
    public static let aiLensSchemaVersion = 2
    public static let maximumDisplayCharacters = 150
    public static let maximumSummaryPromptCharacters = 12_000
    public static let maximumPromptCharacters = 24_000

    public static let modelOptions: [TranscriptAIModelOption] = [
        .init(id: "gemini-3.1-flash-lite", provider: .gemini, displayName: "Gemini 3.1 Flash-Lite"),
        .init(id: "gemini-3.5-flash", provider: .gemini, displayName: "Gemini 3.5 Flash"),
        .init(id: "gemini-2.5-flash-lite", provider: .gemini, displayName: "Gemini 2.5 Flash-Lite"),
        .init(id: "deepseek-v4-flash", provider: .deepSeek, displayName: "DeepSeek V4 Flash"),
        .init(id: "deepseek-v4-pro", provider: .deepSeek, displayName: "DeepSeek V4 Pro"),
        .init(id: "openai/gpt-oss-20b", provider: .groq, displayName: "GPT-OSS 20B"),
        .init(id: "openai/gpt-oss-120b", provider: .groq, displayName: "GPT-OSS 120B"),
    ]

    public static func models(for provider: TranscriptAIProvider) -> [TranscriptAIModelOption] {
        modelOptions.filter { $0.provider == provider }
    }

    public static func defaultModel(for provider: TranscriptAIProvider) -> TranscriptAIModelOption {
        models(for: provider).first!
    }

    public static func validatedModel(
        id: String,
        provider: TranscriptAIProvider
    ) -> TranscriptAIModelOption {
        models(for: provider).first(where: { $0.id == id }) ?? defaultModel(for: provider)
    }

    public static func cacheKey(
        for document: TranscriptBookDocument,
        provider: TranscriptAIProvider,
        modelID: String
    ) -> String {
        "v\(schemaVersion)-\(document.cacheKey)-\(provider.rawValue)-\(stableHash(modelID))"
    }

    public static func briefCacheKey(
        for document: TranscriptBookDocument,
        depth: TranscriptInsightDepth,
        provider: TranscriptAIProvider,
        modelID: String
    ) -> String {
        "lens-v\(aiLensSchemaVersion)-brief-\(depth.rawValue)-\(document.cacheKey)-\(provider.rawValue)-\(stableHash(modelID))"
    }

    public static func questionCacheKey(
        for document: TranscriptBookDocument,
        question: String,
        provider: TranscriptAIProvider,
        modelID: String
    ) -> String {
        let normalizedQuestion = normalized(question).lowercased()
        return "lens-v\(aiLensSchemaVersion)-ask-\(document.cacheKey)-\(provider.rawValue)-\(stableHash(modelID + normalizedQuestion))"
    }

    public static func summaryPromptTranscript(for document: TranscriptBookDocument) -> String {
        promptTranscript(for: document, maximumCharacters: maximumSummaryPromptCharacters)
    }

    /// Builds a bounded, representative input from the complete book. Long videos
    /// are sampled evenly instead of silently using only their beginning.
    public static func promptTranscript(
        for document: TranscriptBookDocument,
        maximumCharacters: Int = maximumPromptCharacters
    ) -> String {
        let paragraphs = document.sections.flatMap(\.paragraphs)
        guard !paragraphs.isEmpty else { return "" }
        let lines = paragraphs.map { paragraph in
            "[\(timestamp(paragraph.startTime))] \(normalized(paragraph.text))"
        }
        let full = lines.joined(separator: "\n")
        guard full.count > maximumCharacters else { return full }

        let averageLineLength = max(1, full.count / max(1, lines.count))
        let targetCount = max(3, maximumCharacters / averageLineLength)
        let stride = max(1, lines.count / targetCount)
        var sampled: [String] = []
        sampled.reserveCapacity(targetCount + 2)
        let lastLine = lines.last ?? ""
        let prefixBudget = max(0, maximumCharacters - lastLine.count - 1)
        var usedCharacters = 0
        var index = 0
        while index < lines.count - 1 {
            let line = lines[index]
            let added = line.count + (sampled.isEmpty ? 0 : 1)
            guard usedCharacters + added <= prefixBudget else { break }
            sampled.append(line)
            usedCharacters += added
            index += stride
        }
        if sampled.last != lastLine { sampled.append(lastLine) }
        return sampled.joined(separator: "\n")
    }

    public static func rateLimitRetryDelay(headerValue: String?) -> TimeInterval {
        guard let headerValue,
              let seconds = TimeInterval(headerValue.trimmingCharacters(in: .whitespacesAndNewlines)),
              seconds.isFinite else {
            return 60
        }
        return min(max(seconds, 1), 86_400)
    }

    public static func sanitizedDisplayText(_ value: String) -> String? {
        let singleLine = normalized(value)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'«»"))
        guard !singleLine.isEmpty else { return nil }
        guard singleLine.count > maximumDisplayCharacters else { return singleLine }
        let end = singleLine.index(singleLine.startIndex, offsetBy: maximumDisplayCharacters - 1)
        let prefix = singleLine[..<end]
        if let boundary = prefix.lastIndex(where: { $0.isWhitespace }) {
            return String(prefix[..<boundary]).trimmingCharacters(in: .whitespaces) + "…"
        }
        return String(prefix) + "…"
    }

    public static func sanitizedLongText(_ value: String, maximumCharacters: Int) -> String? {
        let lines = value
            .components(separatedBy: .newlines)
            .map(normalized)
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return nil }
        let clean = lines.joined(separator: "\n")
        guard clean.count > maximumCharacters else { return clean }
        let end = clean.index(clean.startIndex, offsetBy: max(1, maximumCharacters - 1))
        return String(clean[..<end]).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    /// Cleans provider prose without shortening it. Output length is bounded by
    /// the provider request itself, while the complete generated text remains
    /// available to selection, copying, and the enclosing scroll view.
    public static func sanitizedCompleteText(_ value: String) -> String? {
        let paragraphs = value
            .components(separatedBy: .newlines)
            .map(normalized)
            .filter { !$0.isEmpty }
        guard !paragraphs.isEmpty else { return nil }
        return paragraphs.joined(separator: "\n\n")
    }

    public static func groundedContext(
        for document: TranscriptBookDocument,
        question: String,
        maximumCharacters: Int = maximumPromptCharacters
    ) -> TranscriptGroundedContext {
        let paragraphs = document.sections.flatMap(\.paragraphs)
        guard !paragraphs.isEmpty else { return TranscriptGroundedContext(prompt: "", citations: []) }
        let terms = searchTerms(question)
        let ranked = paragraphs.enumerated().map { index, paragraph in
            let normalizedText = normalized(paragraph.text)
            let lowercased = normalizedText.lowercased()
            let score = terms.reduce(0) { partial, term in
                partial + (lowercased.contains(term) ? 1 : 0)
            }
            return (index: index, paragraph: paragraph, text: normalizedText, score: score)
        }
        let selectedIndexes: Set<Int>
        if terms.isEmpty {
            selectedIndexes = Set(representativeIndexes(count: paragraphs.count, limit: 80))
        } else {
            let strongest = ranked
                .sorted {
                    if $0.score != $1.score { return $0.score > $1.score }
                    return $0.index < $1.index
                }
                .prefix(48)
                .flatMap { item in [item.index - 1, item.index, item.index + 1] }
                .filter { paragraphs.indices.contains($0) }
            selectedIndexes = Set(strongest)
        }
        let ordered = ranked.filter { selectedIndexes.contains($0.index) }
        var citations: [TranscriptAICitation] = []
        var lines: [String] = []
        var used = 0
        for item in ordered {
            let id = "p\(item.index)"
            let line = "[\(id) \(timestamp(item.paragraph.startTime))] \(item.text)"
            let added = line.count + (lines.isEmpty ? 0 : 1)
            guard used + added <= maximumCharacters else { break }
            lines.append(line)
            citations.append(TranscriptAICitation(
                id: id,
                startTime: item.paragraph.startTime,
                text: item.text
            ))
            used += added
        }
        return TranscriptGroundedContext(prompt: lines.joined(separator: "\n"), citations: citations)
    }

    public static func validatedAnswer(
        payload: TranscriptAIAnswerPayload,
        question: String,
        document: TranscriptBookDocument,
        context: TranscriptGroundedContext,
        provider: TranscriptAIProvider,
        modelID: String
    ) -> TranscriptAIAnswer? {
        guard let text = sanitizedLongText(payload.answer, maximumCharacters: 2_400) else { return nil }
        let byID = Dictionary(uniqueKeysWithValues: context.citations.map { ($0.id, $0) })
        var seen = Set<String>()
        let citations = payload.citations.compactMap { id -> TranscriptAICitation? in
            guard seen.insert(id).inserted else { return nil }
            return byID[id]
        }
        guard !citations.isEmpty else { return nil }
        return TranscriptAIAnswer(
            cacheKey: questionCacheKey(
                for: document,
                question: question,
                provider: provider,
                modelID: modelID
            ),
            question: normalized(question),
            text: text,
            citations: citations,
            modelID: modelID
        )
    }

    public static func libraryMatches(
        query: String,
        documents: [TranscriptBookDocument],
        currentVideoID: String?,
        limit: Int = 12
    ) -> [TranscriptLibraryMatch] {
        let terms = searchTerms(query)
        guard !terms.isEmpty else { return [] }
        var matches: [(score: Int, match: TranscriptLibraryMatch)] = []
        var seenDocuments = Set<String>()
        for document in documents where seenDocuments.insert(document.cacheKey).inserted {
            for (index, paragraph) in document.sections.flatMap(\.paragraphs).enumerated() {
                let text = normalized(paragraph.text)
                let lowercased = text.lowercased()
                let matchedTerms = terms.filter { lowercased.contains($0) }
                guard !matchedTerms.isEmpty else { continue }
                let phraseBonus = lowercased.contains(normalized(query).lowercased()) ? 8 : 0
                let score = matchedTerms.count * 3 + phraseBonus
                matches.append((score, TranscriptLibraryMatch(
                    id: "\(document.cacheKey)-\(index)",
                    videoID: document.metadata.videoID,
                    videoTitle: document.metadata.title,
                    channelTitle: document.metadata.channelTitle,
                    startTime: paragraph.startTime,
                    excerpt: boundedExcerpt(text, maximumCharacters: 260),
                    isCurrentVideo: document.metadata.videoID == currentVideoID
                )))
            }
        }
        return matches.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.match.isCurrentVideo != $1.match.isCurrentVideo { return $0.match.isCurrentVideo }
            return $0.match.startTime < $1.match.startTime
        }.prefix(max(0, limit)).map(\.match)
    }

    /// A deterministic, offline-safe excerpt shown immediately while the
    /// optional provider creates a higher-quality summary. It is derived only
    /// from the canonical transcript, so provider failure never leaves the
    /// system Now Playing subtitle empty or invents facts.
    public static func localFallbackText(for document: TranscriptBookDocument) -> String? {
        let paragraphs = document.sections.flatMap(\.paragraphs)
        let candidate = paragraphs.first(where: { normalized($0.text).count >= 32 })
            ?? paragraphs.first(where: { !normalized($0.text).isEmpty })
        guard let candidate else { return nil }
        return sanitizedDisplayText(candidate.text)
    }

    /// Full local main thought for AI Lens. The separate Lock Screen fallback
    /// remains intentionally bounded by `localFallbackText(for:)`.
    public static func localMainThought(for document: TranscriptBookDocument) -> String? {
        let paragraphs = document.sections.flatMap(\.paragraphs)
        let candidate = paragraphs.first(where: { normalized($0.text).count >= 32 })
            ?? paragraphs.first(where: { !normalized($0.text).isEmpty })
        guard let candidate else { return nil }
        return sanitizedCompleteText(candidate.text)
    }

    public static func decodePayload(_ data: Data) throws -> TranscriptSummaryPayload {
        try JSONDecoder().decode(TranscriptSummaryPayload.self, from: data)
    }

    public static func decodeAnswerPayload(_ data: Data) throws -> TranscriptAIAnswerPayload {
        try JSONDecoder().decode(TranscriptAIAnswerPayload.self, from: data)
    }

    private static func normalized(_ value: String) -> String {
        value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func searchTerms(_ value: String) -> [String] {
        var seen = Set<String>()
        return value.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 3 && seen.insert($0).inserted }
    }

    private static func representativeIndexes(count: Int, limit: Int) -> [Int] {
        guard count > limit, limit > 1 else { return Array(0..<count) }
        return (0..<limit).map { Int((Double($0) * Double(count - 1) / Double(limit - 1)).rounded()) }
    }

    private static func boundedExcerpt(_ value: String, maximumCharacters: Int) -> String {
        guard value.count > maximumCharacters else { return value }
        let end = value.index(value.startIndex, offsetBy: maximumCharacters - 1)
        let prefix = value[..<end]
        if let boundary = prefix.lastIndex(where: { $0.isWhitespace }) {
            return String(prefix[..<boundary]).trimmingCharacters(in: .whitespaces) + "…"
        }
        return String(prefix) + "…"
    }

    private static func timestamp(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private static func stableHash(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}
