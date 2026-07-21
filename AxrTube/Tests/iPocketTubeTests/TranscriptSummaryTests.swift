import Foundation
import Testing
@testable import iPocketTubeCore

@Suite("Transcript summary")
struct TranscriptSummaryTests {
    private func document(paragraphCount: Int = 8) -> TranscriptBookDocument {
        let paragraphs = (0..<paragraphCount).map { index in
            TranscriptBookParagraph(
                startTime: Double(index * 45),
                endTime: Double(index * 45 + 40),
                text: "Фрагмент \(index) подробно объясняет надежную работу приложения и важный практический вывод."
            )
        }
        return TranscriptBookDocument(
            formatterVersion: TranscriptBookPolicy.formatterVersion,
            cacheKey: "book-cache-key",
            metadata: TranscriptBookMetadata(
                videoID: "spoken-video",
                title: "Разговорный ролик",
                channelTitle: "Канал",
                duration: Double(paragraphCount * 45)
            ),
            captionTrackID: "ru-track",
            languageCode: "ru",
            generatedAt: Date(timeIntervalSince1970: 0),
            sourceCueCount: paragraphCount,
            sections: [TranscriptBookSection(index: 0, startTime: 0, paragraphs: paragraphs)]
        )
    }

    @Test("Representative prompt covers the beginning and end within the free-tier budget")
    func boundedRepresentativePrompt() {
        let source = document(paragraphCount: 900)
        let prompt = TranscriptSummaryPolicy.promptTranscript(for: source)
        let summaryPrompt = TranscriptSummaryPolicy.summaryPromptTranscript(for: source)

        #expect(prompt.count <= TranscriptSummaryPolicy.maximumPromptCharacters)
        #expect(summaryPrompt.count <= TranscriptSummaryPolicy.maximumSummaryPromptCharacters)
        #expect(prompt.contains("Фрагмент 0"))
        #expect(prompt.contains("Фрагмент 899"))
        #expect(summaryPrompt.contains("Фрагмент 0"))
        #expect(summaryPrompt.contains("Фрагмент 899"))
    }

    @Test("Each provider exposes only its manually selectable models")
    func modelRouting() {
        let gemini = TranscriptSummaryPolicy.models(for: .gemini)
        let deepSeek = TranscriptSummaryPolicy.models(for: .deepSeek)
        let groq = TranscriptSummaryPolicy.models(for: .groq)

        #expect(gemini.map(\.id) == [
            "gemini-3.1-flash-lite",
            "gemini-3.5-flash",
            "gemini-2.5-flash-lite",
        ])
        #expect(deepSeek.map(\.id) == ["deepseek-v4-flash", "deepseek-v4-pro"])
        #expect(groq.map(\.id) == ["openai/gpt-oss-20b", "openai/gpt-oss-120b"])
        #expect(TranscriptSummaryPolicy.defaultModel(for: .gemini).id == "gemini-3.1-flash-lite")
        #expect(TranscriptSummaryPolicy.validatedModel(id: "deepseek-v4-pro", provider: .gemini).provider == .gemini)
    }

    @Test("Rate limit retry respects the server header with safe bounds")
    func rateLimitDelay() {
        #expect(TranscriptSummaryPolicy.rateLimitRetryDelay(headerValue: "2.5") == 2.5)
        #expect(TranscriptSummaryPolicy.rateLimitRetryDelay(headerValue: nil) == 60)
        #expect(TranscriptSummaryPolicy.rateLimitRetryDelay(headerValue: "0") == 1)
        #expect(TranscriptSummaryPolicy.rateLimitRetryDelay(headerValue: "999999") == 86_400)
    }

    @Test("Lock Screen text is one bounded Russian line")
    func boundedDisplayText() {
        let text = Array(repeating: "полезный вывод", count: 30).joined(separator: "\n")
        let result = TranscriptSummaryPolicy.sanitizedDisplayText(text)

        #expect(result != nil)
        #expect((result?.count ?? 0) <= TranscriptSummaryPolicy.maximumDisplayCharacters)
        #expect(result?.contains("\n") == false)
        #expect(result?.hasSuffix("…") == true)
    }

    @Test("Cache identity changes with the canonical book")
    func cacheIdentity() {
        let first = document()
        let second = TranscriptBookDocument(
            formatterVersion: first.formatterVersion,
            cacheKey: "different-book",
            metadata: first.metadata,
            captionTrackID: first.captionTrackID,
            languageCode: first.languageCode,
            generatedAt: first.generatedAt,
            sourceCueCount: first.sourceCueCount,
            sections: first.sections
        )

        let firstKey = TranscriptSummaryPolicy.cacheKey(
            for: first,
            provider: .gemini,
            modelID: "gemini-3.1-flash-lite"
        )
        let secondKey = TranscriptSummaryPolicy.cacheKey(
            for: second,
            provider: .gemini,
            modelID: "gemini-3.1-flash-lite"
        )

        #expect(firstKey != secondKey)
    }

    @Test("Provider and model are part of cache identity")
    func providerModelCacheIdentity() {
        let source = document()
        let geminiLite = TranscriptSummaryPolicy.cacheKey(
            for: source,
            provider: .gemini,
            modelID: "gemini-3.1-flash-lite"
        )
        let geminiFlash = TranscriptSummaryPolicy.cacheKey(
            for: source,
            provider: .gemini,
            modelID: "gemini-3.5-flash"
        )
        let deepSeek = TranscriptSummaryPolicy.cacheKey(
            for: source,
            provider: .deepSeek,
            modelID: "deepseek-v4-flash"
        )

        #expect(geminiLite != geminiFlash)
        #expect(geminiLite != deepSeek)
    }

    @Test("Strict JSON payload does not accept arbitrary provider prose")
    func strictPayload() throws {
        let valid = Data(#"{"summary":"Короткая суть ролика."}"#.utf8)
        #expect(try TranscriptSummaryPolicy.decodePayload(valid).summary == "Короткая суть ролика.")
        #expect(throws: (any Error).self) {
            try TranscriptSummaryPolicy.decodePayload(Data("Вот краткая суть".utf8))
        }
    }

    @Test("Canonical transcript provides an immediate bounded offline fallback")
    func localFallback() {
        let fallback = TranscriptSummaryPolicy.localFallbackText(for: document())

        #expect(fallback?.contains("Фрагмент 0") == true)
        #expect((fallback?.count ?? 0) <= TranscriptSummaryPolicy.maximumDisplayCharacters)
        #expect(fallback?.contains("\n") == false)
    }

    @Test("Off mode keeps system Now Playing as the only playback card")
    func noDuplicatePlaybackCardByDefault() {
        #expect(!PlaybackLockScreenPolicy.usesPlaybackLiveActivity(for: .off))
        #expect(PlaybackLockScreenPolicy.usesPlaybackLiveActivity(for: .progress))
        var arbitration = LiveActivityArbitrationPolicy()
        let download = arbitration.beginDownload(itemID: "download-only")
        #expect(download.shouldPresent)
        #expect(arbitration.playbackLease == nil)
    }

    @Test("AI Lens depth owns a distinct cache identity")
    func briefDepthCacheIdentity() {
        let source = document()
        let quick = TranscriptSummaryPolicy.briefCacheKey(
            for: source,
            depth: .quick,
            provider: .deepSeek,
            modelID: "deepseek-v4-flash"
        )
        let detailed = TranscriptSummaryPolicy.briefCacheKey(
            for: source,
            depth: .detailed,
            provider: .deepSeek,
            modelID: "deepseek-v4-flash"
        )

        #expect(quick != detailed)
        #expect(quick.contains("brief-quick"))
    }

    @Test("Question context keeps timestamps and prioritizes relevant paragraphs")
    func groundedQuestionContext() {
        let source = document(paragraphCount: 20)
        let context = TranscriptSummaryPolicy.groundedContext(
            for: source,
            question: "Что сказано про фрагмент 17?"
        )

        #expect(context.prompt.contains("[p17 12:45]"))
        #expect(context.citations.contains(where: { $0.id == "p17" && $0.startTime == 765 }))
    }

    @Test("Provider answer is accepted only with real transcript evidence")
    func groundedAnswerValidation() throws {
        let source = document()
        let question = "Какой практический вывод?"
        let context = TranscriptSummaryPolicy.groundedContext(for: source, question: question)
        let validID = try #require(context.citations.first?.id)
        let valid = TranscriptSummaryPolicy.validatedAnswer(
            payload: TranscriptAIAnswerPayload(answer: "Надежность проверяется на практике.", citations: [validID]),
            question: question,
            document: source,
            context: context,
            provider: .groq,
            modelID: "openai/gpt-oss-20b"
        )
        let invented = TranscriptSummaryPolicy.validatedAnswer(
            payload: TranscriptAIAnswerPayload(answer: "Неподтвержденный ответ.", citations: ["p999"]),
            question: question,
            document: source,
            context: context,
            provider: .groq,
            modelID: "openai/gpt-oss-20b"
        )

        #expect(valid?.citations.count == 1)
        #expect(invented == nil)
    }

    @Test("Local library search links matching saved books without network")
    func localLibrarySearch() {
        let first = document()
        let secondParagraph = TranscriptBookParagraph(
            startTime: 95,
            endTime: 130,
            text: "Отдельный ролик подробно разбирает экономию батареи и фоновые задачи приложения."
        )
        let second = TranscriptBookDocument(
            formatterVersion: TranscriptBookPolicy.formatterVersion,
            cacheKey: "second-book",
            metadata: TranscriptBookMetadata(
                videoID: "battery-video",
                title: "Экономия батареи",
                channelTitle: "Практика"
            ),
            captionTrackID: "ru-track",
            languageCode: "ru",
            generatedAt: Date(timeIntervalSince1970: 1),
            sourceCueCount: 1,
            sections: [TranscriptBookSection(index: 0, startTime: 95, paragraphs: [secondParagraph])]
        )

        let matches = TranscriptSummaryPolicy.libraryMatches(
            query: "экономия батареи",
            documents: [first, second],
            currentVideoID: first.metadata.videoID
        )

        #expect(matches.first?.videoID == "battery-video")
        #expect(matches.first?.startTime == 95)
        #expect(matches.first?.isCurrentVideo == false)
    }
}
