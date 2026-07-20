import Foundation

public enum TranscriptBookState: Equatable, Sendable {
    case collecting
    case ready
    case unavailable
    case failed
}

public struct TranscriptBookMetadata: Codable, Equatable, Sendable {
    public let videoID: String
    public let title: String
    public let channelTitle: String
    public let videoURL: URL
    public let duration: TimeInterval?

    public init(
        videoID: String,
        title: String,
        channelTitle: String,
        videoURL: URL? = nil,
        duration: TimeInterval? = nil
    ) {
        self.videoID = videoID
        self.title = title
        self.channelTitle = channelTitle
        self.videoURL = videoURL
            ?? URL(string: "https://www.youtube.com/watch?v=\(videoID)")!
        self.duration = duration
    }
}

public struct TranscriptBookParagraph: Codable, Equatable, Sendable {
    public let startTime: TimeInterval
    public let endTime: TimeInterval
    public let text: String

    public init(startTime: TimeInterval, endTime: TimeInterval, text: String) {
        self.startTime = startTime
        self.endTime = endTime
        self.text = text
    }
}

public struct TranscriptBookSection: Codable, Equatable, Identifiable, Sendable {
    public let index: Int
    public let startTime: TimeInterval
    public let paragraphs: [TranscriptBookParagraph]

    public init(index: Int, startTime: TimeInterval, paragraphs: [TranscriptBookParagraph]) {
        self.index = index
        self.startTime = startTime
        self.paragraphs = paragraphs
    }

    public var id: String { TranscriptBookPolicy.anchor(for: startTime) }
}

public struct TranscriptBookDocument: Codable, Equatable, Sendable {
    public let formatterVersion: Int
    public let cacheKey: String
    public let metadata: TranscriptBookMetadata
    public let captionTrackID: String
    public let languageCode: String
    public let generatedAt: Date
    public let sourceCueCount: Int
    public let sections: [TranscriptBookSection]

    public init(
        formatterVersion: Int,
        cacheKey: String,
        metadata: TranscriptBookMetadata,
        captionTrackID: String,
        languageCode: String,
        generatedAt: Date,
        sourceCueCount: Int,
        sections: [TranscriptBookSection]
    ) {
        self.formatterVersion = formatterVersion
        self.cacheKey = cacheKey
        self.metadata = metadata
        self.captionTrackID = captionTrackID
        self.languageCode = languageCode
        self.generatedAt = generatedAt
        self.sourceCueCount = sourceCueCount
        self.sections = sections
    }

    public var languageDisplayName: String {
        switch TranscriptBookPolicy.baseLanguage(languageCode) {
        case "ru": "Русский"
        case "en": "English"
        default: languageCode
        }
    }

    public var duration: TimeInterval {
        max(metadata.duration ?? 0, sections.last?.paragraphs.last?.endTime ?? 0)
    }

    public var paragraphCount: Int {
        sections.reduce(0) { $0 + $1.paragraphs.count }
    }

    public var safeBaseFilename: String {
        let language = TranscriptBookPolicy.baseLanguage(languageCode).uppercased()
        return TranscriptExportPolicy.safeFilename("\(metadata.title) - \(language)")
    }

    public var markdown: String {
        TranscriptBookPolicy.markdown(for: self)
    }

    public var html: String {
        TranscriptBookPolicy.html(for: self)
    }

    public var searchableText: String {
        TranscriptBookPolicy.searchableText(for: self)
    }
}

public struct TranscriptBookRequest: Equatable, Sendable {
    public let metadata: TranscriptBookMetadata
    public let captionTrackID: String
    public let languageCode: String
    public let cues: [CaptionCue]
    public let forceRebuild: Bool

    public init(
        metadata: TranscriptBookMetadata,
        captionTrackID: String,
        languageCode: String,
        cues: [CaptionCue],
        forceRebuild: Bool = false
    ) {
        self.metadata = metadata
        self.captionTrackID = captionTrackID
        self.languageCode = languageCode
        self.cues = CaptionTranscriptPolicy.normalizedCues(cues)
        self.forceRebuild = forceRebuild
    }
}

public struct TranscriptBookArtifacts: Equatable, Sendable {
    public let markdownURL: URL
    public let htmlURL: URL
    public let pdfURL: URL
    public let pageCount: Int

    public init(markdownURL: URL, htmlURL: URL, pdfURL: URL, pageCount: Int) {
        self.markdownURL = markdownURL
        self.htmlURL = htmlURL
        self.pdfURL = pdfURL
        self.pageCount = pageCount
    }
}

public struct TranscriptBookResult: Equatable, Sendable {
    public let document: TranscriptBookDocument
    public let artifacts: TranscriptBookArtifacts
    public let wasCached: Bool

    public init(
        document: TranscriptBookDocument,
        artifacts: TranscriptBookArtifacts,
        wasCached: Bool
    ) {
        self.document = document
        self.artifacts = artifacts
        self.wasCached = wasCached
    }
}

public enum TranscriptBookFailure: Error, Equatable, Sendable {
    case noCaptions
    case unsupportedLanguage
    case invalidDocument
    case exportFailed
}

public enum TranscriptBookPolicy {
    public static let formatterVersion = 2
    public static let sectionDuration: TimeInterval = 5 * 60
    public static let minimumParagraphWords = 35
    public static let targetParagraphWords = 75
    public static let maximumParagraphWords = 120

    public static func preferredTracks(in tracks: [CaptionTrack]) -> [CaptionTrack] {
        let supported = tracks.filter {
            let language = baseLanguage($0.languageCode)
            return language == "ru" || language == "en"
        }
        return supported.sorted { lhs, rhs in
            let lhsLanguage = baseLanguage(lhs.languageCode)
            let rhsLanguage = baseLanguage(rhs.languageCode)
            if lhsLanguage != rhsLanguage { return lhsLanguage == "ru" }
            if lhs.isAutoGenerated != rhs.isAutoGenerated { return !lhs.isAutoGenerated }
            return lhs.id < rhs.id
        }
    }

    public static func preferredTrack(in tracks: [CaptionTrack]) -> CaptionTrack? {
        preferredTracks(in: tracks).first
    }

    public static func makeDocument(
        request: TranscriptBookRequest,
        generatedAt: Date = Date()
    ) throws -> TranscriptBookDocument {
        let cues = readableCues(request.cues)
        guard !cues.isEmpty else { throw TranscriptBookFailure.noCaptions }
        let language = baseLanguage(request.languageCode)
        guard language == "ru" || language == "en" else {
            throw TranscriptBookFailure.unsupportedLanguage
        }
        let paragraphs = makeParagraphs(from: cues)
        guard !paragraphs.isEmpty else { throw TranscriptBookFailure.invalidDocument }
        let sections = makeSections(from: paragraphs)
        let key = cacheKey(
            metadata: request.metadata,
            captionTrackID: request.captionTrackID,
            languageCode: language,
            cues: cues
        )
        return TranscriptBookDocument(
            formatterVersion: formatterVersion,
            cacheKey: key,
            metadata: request.metadata,
            captionTrackID: request.captionTrackID,
            languageCode: language,
            generatedAt: generatedAt,
            sourceCueCount: cues.count,
            sections: sections
        )
    }

    public static func cacheKey(
        metadata: TranscriptBookMetadata,
        captionTrackID: String,
        languageCode: String,
        cues: [CaptionCue]
    ) -> String {
        stableHash(
            "v\(formatterVersion)|\(metadata.videoID)|\(captionTrackID)|" +
            "\(baseLanguage(languageCode))|\(sourceHash(cues: cues))"
        )
    }

    public static func sourceHash(cues: [CaptionCue]) -> String {
        let value = CaptionTranscriptPolicy.normalizedCues(cues).map {
            let start = Int(($0.startTime * 1_000).rounded())
            let end = Int(($0.endTime * 1_000).rounded())
            return "\(start)|\(end)|\($0.text)"
        }.joined(separator: "\n")
        return stableHash(value)
    }

    public static func baseLanguage(_ code: String) -> String {
        code.lowercased().split(separator: "-").first.map(String.init) ?? code.lowercased()
    }

    public static func anchor(for time: TimeInterval) -> String {
        "section-\(max(0, Int(time.rounded(.down))))"
    }

    public static func markdownEscaped(_ value: String) -> String {
        var result = value.replacingOccurrences(of: "\\", with: "\\\\")
        for character in ["`", "*", "_", "[", "]", "<", ">", "#", "|"] {
            result = result.replacingOccurrences(of: character, with: "\\\(character)")
        }
        return result
    }

    public static func markdown(for document: TranscriptBookDocument) -> String {
        let title = markdownEscaped(document.metadata.title.isEmpty ? "Стенограмма" : document.metadata.title)
        let author = markdownEscaped(document.metadata.channelTitle.isEmpty ? "Неизвестный канал" : document.metadata.channelTitle)
        let date = ISO8601DateFormatter().string(from: document.generatedAt)
        var lines = [
            "# \(title)",
            "",
            "> \(author)",
            "",
            "- [Исходное видео](\(document.metadata.videoURL.absoluteString))",
            "- Язык: \(document.languageDisplayName)",
            "- Длительность: \(TranscriptExportPolicy.timestamp(document.duration))",
            "- Создано: \(date)",
            "",
            "## Оглавление",
            "",
        ]
        for section in document.sections {
            let timestamp = TranscriptExportPolicy.timestamp(section.startTime)
            lines.append("- [Раздел \(section.index + 1), \(timestamp)](#\(section.id))")
        }
        lines.append(contentsOf: ["", "---", ""])
        for section in document.sections {
            let timestamp = TranscriptExportPolicy.timestamp(section.startTime)
            lines.append("<a id=\"\(section.id)\"></a>")
            lines.append("## Раздел \(section.index + 1) · \(timestamp)")
            lines.append("")
            for paragraph in section.paragraphs {
                let seconds = max(0, Int(paragraph.startTime.rounded(.down)))
                let marker = TranscriptExportPolicy.timestamp(paragraph.startTime)
                lines.append("### [\(marker)](\(document.metadata.videoURL.absoluteString)&t=\(seconds)s)")
                lines.append("")
                lines.append(markdownEscaped(paragraph.text))
                lines.append("")
            }
        }
        lines.append(contentsOf: [
            "---",
            "",
            "[Открыть исходный ролик](\(document.metadata.videoURL.absoluteString))",
            "",
        ])
        return lines.joined(separator: "\n")
    }

    public static func searchableText(for document: TranscriptBookDocument) -> String {
        let date = ISO8601DateFormatter().string(from: document.generatedAt)
        var lines = [
            document.metadata.title.isEmpty ? "Стенограмма" : document.metadata.title,
            document.metadata.channelTitle,
            document.metadata.videoURL.absoluteString,
            "Язык: \(document.languageDisplayName)",
            "Длительность: \(TranscriptExportPolicy.timestamp(document.duration))",
            "Создано: \(date)",
            "",
            "Оглавление",
        ]
        lines.append(contentsOf: document.sections.map {
            "Раздел \($0.index + 1), \(TranscriptExportPolicy.timestamp($0.startTime))"
        })
        for section in document.sections {
            lines.append("")
            lines.append("Раздел \(section.index + 1), \(TranscriptExportPolicy.timestamp(section.startTime))")
            for paragraph in section.paragraphs {
                lines.append("\(TranscriptExportPolicy.timestamp(paragraph.startTime))  \(paragraph.text)")
            }
        }
        lines.append("")
        lines.append("Исходное видео: \(document.metadata.videoURL.absoluteString)")
        return lines.joined(separator: "\n") + "\n"
    }

    public static func htmlEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    public static func html(for document: TranscriptBookDocument) -> String {
        let title = htmlEscaped(document.metadata.title.isEmpty ? "Стенограмма" : document.metadata.title)
        let author = htmlEscaped(document.metadata.channelTitle.isEmpty ? "Неизвестный канал" : document.metadata.channelTitle)
        let sourceURL = htmlEscaped(document.metadata.videoURL.absoluteString)
        let language = htmlEscaped(document.languageDisplayName)
        let languageCode = htmlEscaped(baseLanguage(document.languageCode))
        let created = htmlEscaped(ISO8601DateFormatter().string(from: document.generatedAt))
        let duration = htmlEscaped(TranscriptExportPolicy.timestamp(document.duration))
        let tableOfContents = document.sections.map { section in
            let timestamp = htmlEscaped(TranscriptExportPolicy.timestamp(section.startTime))
            return "<a href=\"#\(section.id)\"><span>Раздел \(section.index + 1)</span><time>\(timestamp)</time></a>"
        }.joined(separator: "\n")
        let chapters = document.sections.map { section in
            let timestamp = htmlEscaped(TranscriptExportPolicy.timestamp(section.startTime))
            let paragraphs = section.paragraphs.map { paragraph in
                let marker = htmlEscaped(TranscriptExportPolicy.timestamp(paragraph.startTime))
                let seconds = max(0, Int(paragraph.startTime.rounded(.down)))
                let text = htmlEscaped(paragraph.text)
                return """
                <article class="paragraph">
                  <a class="timestamp" href="\(sourceURL)&amp;t=\(seconds)s" aria-label="Открыть видео с отметки \(marker)">\(marker)</a>
                  <p>\(text)</p>
                </article>
                """
            }.joined(separator: "\n")
            return """
            <section class="chapter surface" id="\(section.id)">
              <header class="chapter-title">
                <span class="chapter-number">\(section.index + 1)</span>
                <div><p>Раздел \(section.index + 1)</p><time>\(timestamp)</time></div>
              </header>
              \(paragraphs)
            </section>
            """
        }.joined(separator: "\n")

        return """
        <!doctype html>
        <html lang="\(languageCode)">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
          <meta name="color-scheme" content="light dark">
          <title>\(title)</title>
          <style>
            :root {
              color-scheme: light dark;
              --accent: #ff3b30;
              --accent-soft: rgba(255, 59, 48, .12);
              --page: #f2f2f7;
              --surface: rgba(255, 255, 255, .72);
              --surface-solid: #ffffff;
              --text: #1c1c1e;
              --secondary: #636366;
              --hairline: rgba(60, 60, 67, .16);
              --shadow: 0 18px 60px rgba(36, 36, 40, .12);
              --radius: 30px;
              font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Segoe UI", sans-serif;
              font-synthesis: none;
            }
            @media (prefers-color-scheme: dark) {
              :root {
                --page: #000000;
                --surface: rgba(36, 36, 40, .74);
                --surface-solid: #1c1c1e;
                --text: #f5f5f7;
                --secondary: #aeaeb2;
                --hairline: rgba(235, 235, 245, .18);
                --shadow: 0 22px 70px rgba(0, 0, 0, .42);
              }
            }
            * { box-sizing: border-box; }
            html { scroll-behavior: smooth; background: var(--page); }
            body {
              margin: 0;
              min-height: 100vh;
              background:
                radial-gradient(circle at 12% 0%, rgba(255, 59, 48, .15), transparent 32rem),
                radial-gradient(circle at 92% 8%, rgba(10, 132, 255, .10), transparent 30rem),
                var(--page);
              color: var(--text);
              font-size: clamp(17px, 1.1vw, 19px);
              line-height: 1.64;
              -webkit-font-smoothing: antialiased;
            }
            a { color: inherit; }
            .topbar {
              position: sticky;
              z-index: 10;
              top: 0;
              display: flex;
              align-items: center;
              justify-content: space-between;
              min-height: 58px;
              padding: calc(8px + env(safe-area-inset-top)) max(20px, env(safe-area-inset-right)) 8px max(20px, env(safe-area-inset-left));
              border-bottom: 1px solid var(--hairline);
              background: color-mix(in srgb, var(--page) 72%, transparent);
              -webkit-backdrop-filter: blur(30px) saturate(170%);
              backdrop-filter: blur(30px) saturate(170%);
            }
            .brand { display: flex; align-items: center; gap: 10px; font-weight: 750; letter-spacing: -.02em; }
            .brand-mark { width: 14px; height: 22px; border-radius: 4px; background: var(--accent); box-shadow: 0 5px 18px rgba(255, 59, 48, .35); }
            .language { color: var(--secondary); font-size: .82rem; font-weight: 650; }
            main { width: min(920px, 100%); margin: 0 auto; padding: 42px max(18px, env(safe-area-inset-right)) 84px max(18px, env(safe-area-inset-left)); }
            .surface {
              background: var(--surface);
              border: 1px solid var(--hairline);
              border-radius: var(--radius);
              box-shadow: var(--shadow);
              -webkit-backdrop-filter: blur(34px) saturate(160%);
              backdrop-filter: blur(34px) saturate(160%);
            }
            .hero { padding: clamp(28px, 6vw, 64px); overflow: hidden; position: relative; }
            .hero::after { content: ""; position: absolute; width: 240px; height: 240px; border-radius: 50%; right: -100px; top: -120px; background: var(--accent-soft); }
            .eyebrow { margin: 0 0 18px; color: var(--accent); font-size: .76rem; font-weight: 800; letter-spacing: .12em; text-transform: uppercase; }
            h1 { max-width: 760px; margin: 0; font-size: clamp(2.25rem, 7vw, 4.8rem); line-height: 1.02; letter-spacing: -.055em; text-wrap: balance; }
            .author { margin: 22px 0 0; color: var(--secondary); font-size: 1.08rem; font-weight: 620; }
            .metadata { display: flex; flex-wrap: wrap; gap: 8px; margin-top: 28px; }
            .metadata span { padding: 7px 12px; border-radius: 999px; background: var(--accent-soft); color: var(--text); font-size: .78rem; font-weight: 700; }
            .source { display: inline-flex; align-items: center; gap: 8px; margin-top: 28px; color: var(--accent); font-weight: 700; text-decoration: none; }
            .source:hover { text-decoration: underline; }
            .toc { margin-top: 22px; padding: 14px; display: grid; grid-template-columns: repeat(auto-fit, minmax(210px, 1fr)); gap: 8px; }
            .toc a { display: flex; justify-content: space-between; gap: 20px; padding: 13px 15px; border-radius: 18px; text-decoration: none; background: color-mix(in srgb, var(--surface-solid) 70%, transparent); }
            .toc a:hover { background: var(--accent-soft); }
            .toc span { font-weight: 700; }
            .toc time { color: var(--secondary); font-variant-numeric: tabular-nums; }
            .chapter { margin-top: 22px; padding: clamp(24px, 5vw, 50px); }
            .chapter-title { display: flex; align-items: center; gap: 15px; margin-bottom: 30px; padding-bottom: 24px; border-bottom: 1px solid var(--hairline); }
            .chapter-number { display: grid; place-items: center; flex: 0 0 48px; width: 48px; height: 48px; border-radius: 16px; background: var(--accent); color: white; font-size: 1.15rem; font-weight: 800; box-shadow: 0 10px 28px rgba(255, 59, 48, .28); }
            .chapter-title p { margin: 0; font-size: 1.35rem; font-weight: 780; letter-spacing: -.025em; }
            .chapter-title time { display: block; color: var(--secondary); font-size: .82rem; font-variant-numeric: tabular-nums; }
            .paragraph { display: grid; grid-template-columns: 64px minmax(0, 1fr); gap: 18px; align-items: start; margin: 0 0 28px; scroll-margin-top: 82px; }
            .paragraph:last-child { margin-bottom: 0; }
            .paragraph p { margin: 0; text-wrap: pretty; overflow-wrap: anywhere; }
            .timestamp { position: sticky; top: 76px; display: inline-flex; justify-content: center; padding: 5px 8px; border-radius: 999px; background: var(--accent-soft); color: var(--accent); font-size: .72rem; font-weight: 800; font-variant-numeric: tabular-nums; text-decoration: none; }
            footer { padding: 28px max(20px, env(safe-area-inset-right)) calc(28px + env(safe-area-inset-bottom)) max(20px, env(safe-area-inset-left)); text-align: center; color: var(--secondary); font-size: .78rem; }
            @media (max-width: 620px) {
              main { padding-top: 20px; }
              .surface { --radius: 24px; }
              .hero { padding: 30px 24px; }
              .chapter { padding: 28px 22px; }
              .paragraph { grid-template-columns: 1fr; gap: 9px; margin-bottom: 30px; }
              .timestamp { position: static; width: fit-content; }
              .toc { grid-template-columns: 1fr; }
            }
            @media (prefers-reduced-transparency: reduce) {
              .topbar, .surface { background: var(--surface-solid); -webkit-backdrop-filter: none; backdrop-filter: none; }
            }
            @media (prefers-contrast: more) {
              :root { --hairline: currentColor; }
              .surface { border-width: 2px; box-shadow: none; }
            }
            @media print {
              .topbar { position: static; background: white; }
              body { background: white; color: black; font-size: 11pt; }
              main { width: 100%; padding: 0; }
              .surface { background: white; border: 1px solid #d1d1d6; box-shadow: none; break-inside: avoid; }
              .hero, .chapter { margin-top: 18pt; }
              .timestamp { position: static; }
            }
          </style>
        </head>
        <body>
          <header class="topbar">
            <div class="brand"><span class="brand-mark" aria-hidden="true"></span>AxrTube</div>
            <div class="language">\(language)</div>
          </header>
          <main>
            <section class="hero surface">
              <p class="eyebrow">Книга стенограммы</p>
              <h1>\(title)</h1>
              <p class="author">\(author)</p>
              <div class="metadata"><span>\(language)</span><span>\(duration)</span><span>\(created)</span></div>
              <a class="source" href="\(sourceURL)">Открыть исходное видео</a>
            </section>
            <nav class="toc surface" aria-label="Оглавление">\(tableOfContents)</nav>
            \(chapters)
          </main>
          <footer>Создано локально в AxrTube · <a href="\(sourceURL)">Исходное видео</a></footer>
        </body>
        </html>
        """
    }

    private static func readableCues(_ source: [CaptionCue]) -> [CaptionCue] {
        let normalized = CaptionTranscriptPolicy.normalizedCues(source)
        var result: [CaptionCue] = []
        var previousText = ""
        for cue in normalized {
            let novel = novelText(previous: previousText, candidate: cue.text)
            guard !novel.isEmpty else { continue }
            result.append(CaptionCue(
                startTime: cue.startTime,
                endTime: cue.endTime,
                text: novel,
                activationTime: cue.activationTime
            ))
            previousText = cue.text
        }
        return result
    }

    private static func makeParagraphs(from cues: [CaptionCue]) -> [TranscriptBookParagraph] {
        var result: [TranscriptBookParagraph] = []
        var group: [CaptionCue] = []

        func flush() {
            guard let first = group.first, let last = group.last else { return }
            let text = group.map(\.text).joined(separator: " ")
                .split(whereSeparator: { $0.isWhitespace })
                .joined(separator: " ")
            if !text.isEmpty {
                result.append(TranscriptBookParagraph(
                    startTime: first.startTime,
                    endTime: last.endTime,
                    text: text
                ))
            }
            group.removeAll(keepingCapacity: true)
        }

        for cue in cues {
            if let first = group.first, let previous = group.last {
                let currentWords = group.reduce(0) { $0 + wordCount($1.text) }
                let nextWords = currentWords + wordCount(cue.text)
                let gap = cue.startTime - previous.endTime
                let crossesSection = Int(first.startTime / sectionDuration)
                    != Int(cue.startTime / sectionDuration)
                let naturalBreak = currentWords >= minimumParagraphWords
                    && previous.text.hasTranscriptTerminalPunctuation
                    && cue.startTime - first.startTime >= 20
                if gap > 4
                    || crossesSection
                    || nextWords > maximumParagraphWords
                    || (currentWords >= targetParagraphWords && naturalBreak)
                    || (naturalBreak && cue.startTime - first.startTime >= 45) {
                    flush()
                }
            }
            group.append(cue)
        }
        flush()
        return result
    }

    private static func makeSections(
        from paragraphs: [TranscriptBookParagraph]
    ) -> [TranscriptBookSection] {
        var buckets: [[TranscriptBookParagraph]] = []
        var currentBucket: Int?
        for paragraph in paragraphs {
            let bucket = Int(paragraph.startTime / sectionDuration)
            if bucket != currentBucket {
                buckets.append([])
                currentBucket = bucket
            }
            buckets[buckets.count - 1].append(paragraph)
        }
        return buckets.enumerated().compactMap { index, paragraphs in
            guard let first = paragraphs.first else { return nil }
            return TranscriptBookSection(
                index: index,
                startTime: first.startTime,
                paragraphs: paragraphs
            )
        }
    }

    private static func novelText(previous: String, candidate: String) -> String {
        let previousWords = previous.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let candidateWords = candidate.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !candidateWords.isEmpty else { return "" }
        let maxOverlap = min(min(previousWords.count, candidateWords.count), 32)
        if maxOverlap > 0 {
            for count in stride(from: maxOverlap, through: 1, by: -1) {
                let lhs = previousWords.suffix(count).map(normalizedWord)
                let rhs = candidateWords.prefix(count).map(normalizedWord)
                if lhs == rhs {
                    return candidateWords.dropFirst(count).joined(separator: " ")
                }
            }
        }
        if normalizedWords(previous) == normalizedWords(candidate) { return "" }
        return candidateWords.joined(separator: " ")
    }

    private static func normalizedWords(_ value: String) -> [String] {
        value.split(whereSeparator: { $0.isWhitespace }).map { normalizedWord(String($0)) }
    }

    private static func normalizedWord(_ value: String) -> String {
        value.lowercased().trimmingCharacters(in: .punctuationCharacters)
    }

    private static func wordCount(_ value: String) -> Int {
        value.split(whereSeparator: { $0.isWhitespace }).count
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

private extension String {
    var hasTranscriptTerminalPunctuation: Bool {
        guard let last else { return false }
        return ".!?;:…".contains(last)
    }
}
