import CoreGraphics
import CoreText
import Foundation
import iPocketTubeCore

#if canImport(UIKit)
import UIKit
private typealias BookFont = UIFont
private typealias BookColor = UIColor
private let bookLabelColor = UIColor.label
private let bookSecondaryLabelColor = UIColor.secondaryLabel
private let bookPageColor = UIColor(red: 0.965, green: 0.965, blue: 0.98, alpha: 1)
private let bookSurfaceColor = UIColor.white
private let bookAccentColor = UIColor(red: 1, green: 0.231, blue: 0.188, alpha: 1)
private let bookAccentSoftColor = UIColor(red: 1, green: 0.925, blue: 0.918, alpha: 1)
#elseif canImport(AppKit)
import AppKit
private typealias BookFont = NSFont
private typealias BookColor = NSColor
private let bookLabelColor = NSColor.labelColor
private let bookSecondaryLabelColor = NSColor.secondaryLabelColor
private let bookPageColor = NSColor(deviceRed: 0.965, green: 0.965, blue: 0.98, alpha: 1)
private let bookSurfaceColor = NSColor.white
private let bookAccentColor = NSColor(deviceRed: 1, green: 0.231, blue: 0.188, alpha: 1)
private let bookAccentSoftColor = NSColor(deviceRed: 1, green: 0.925, blue: 0.918, alpha: 1)
#endif

struct TranscriptBookPDFRenderer: Sendable {
    private let pageRect = CGRect(x: 0, y: 0, width: 595, height: 842)
    private let horizontalMargin: CGFloat = 58
    private let topMargin: CGFloat = 72
    private let bottomMargin: CGFloat = 62

    func render(document: TranscriptBookDocument, to url: URL) throws -> Int {
        guard let consumer = CGDataConsumer(url: url as CFURL) else {
            throw TranscriptBookFailure.exportFailed
        }
        var mediaBox = pageRect
        let metadata: [CFString: Any] = [
            kCGPDFContextTitle: document.metadata.title,
            kCGPDFContextAuthor: document.metadata.channelTitle,
            kCGPDFContextSubject: "Стенограмма видео, \(document.languageDisplayName)",
            kCGPDFContextCreator: "AxrTube",
        ]
        guard let context = CGContext(
            consumer: consumer,
            mediaBox: &mediaBox,
            metadata as CFDictionary
        ) else {
            throw TranscriptBookFailure.exportFailed
        }

        drawCover(document: document, context: context)
        var pageNumber = 1

        let attributed = makeAttributedBody(document)
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let bodyRect = CGRect(
            x: horizontalMargin,
            y: bottomMargin,
            width: pageRect.width - horizontalMargin * 2,
            height: pageRect.height - topMargin - bottomMargin
        )
        var location = 0
        while location < attributed.length {
            pageNumber += 1
            context.beginPDFPage([
                kCGPDFContextMediaBox as String: pageRect,
                kCGPDFContextTitle as String: document.metadata.title,
            ] as CFDictionary)
            drawHeader(document: document, pageNumber: pageNumber, context: context)
            let path = CGPath(rect: bodyRect, transform: nil)
            let frame = CTFramesetterCreateFrame(
                framesetter,
                CFRange(location: location, length: 0),
                path,
                nil
            )
            CTFrameDraw(frame, context)
            let visible = CTFrameGetVisibleStringRange(frame)
            guard visible.length > 0 else {
                context.endPDFPage()
                context.closePDF()
                throw TranscriptBookFailure.exportFailed
            }
            location += visible.length
            let linkRect = CGRect(
                x: horizontalMargin,
                y: 24,
                width: pageRect.width - horizontalMargin * 2,
                height: 22
            )
            context.setURL(document.metadata.videoURL as CFURL, for: linkRect)
            context.endPDFPage()
        }
        context.closePDF()
        guard pageNumber > 0 else { throw TranscriptBookFailure.exportFailed }
        return pageNumber
    }

    private func drawCover(document: TranscriptBookDocument, context: CGContext) {
        context.beginPDFPage([
            kCGPDFContextMediaBox as String: pageRect,
            kCGPDFContextTitle as String: document.metadata.title,
        ] as CFDictionary)
        context.setFillColor(bookPageColor.cgColor)
        context.fill(pageRect)

        let card = CGRect(x: 42, y: 124, width: pageRect.width - 84, height: pageRect.height - 176)
        context.setFillColor(bookSurfaceColor.cgColor)
        context.addPath(CGPath(roundedRect: card, cornerWidth: 28, cornerHeight: 28, transform: nil))
        context.fillPath()

        context.setFillColor(bookAccentSoftColor.cgColor)
        context.fillEllipse(in: CGRect(x: pageRect.width - 210, y: pageRect.height - 170, width: 180, height: 180))
        context.setFillColor(bookAccentColor.cgColor)
        context.addPath(CGPath(roundedRect: CGRect(x: 70, y: pageRect.height - 116, width: 16, height: 30), cornerWidth: 5, cornerHeight: 5, transform: nil))
        context.fillPath()

        drawText(
            NSAttributedString(
                string: "AxrTube  Книга стенограммы",
                attributes: [
                    .font: BookFont.systemFont(ofSize: 11, weight: .semibold),
                    .foregroundColor: bookAccentColor,
                ]
            ),
            in: CGRect(x: 98, y: pageRect.height - 117, width: 360, height: 34),
            context: context
        )

        let titleStyle = NSMutableParagraphStyle()
        titleStyle.lineBreakMode = .byWordWrapping
        titleStyle.lineSpacing = 2
        drawText(
            NSAttributedString(
                string: document.metadata.title.isEmpty ? "Стенограмма" : document.metadata.title,
                attributes: [
                    .font: BookFont.systemFont(ofSize: 34, weight: .bold),
                    .foregroundColor: bookLabelColor,
                    .paragraphStyle: titleStyle,
                ]
            ),
            in: CGRect(x: 70, y: 480, width: pageRect.width - 140, height: 185),
            context: context
        )

        let meta = [
            document.metadata.channelTitle,
            "Язык: \(document.languageDisplayName)",
            "Длительность: \(TranscriptExportPolicy.timestamp(document.duration))",
            "Создано: \(ISO8601DateFormatter().string(from: document.generatedAt))",
        ].joined(separator: "\n")
        let metaStyle = NSMutableParagraphStyle()
        metaStyle.lineSpacing = 6
        drawText(
            NSAttributedString(
                string: meta,
                attributes: [
                    .font: BookFont.systemFont(ofSize: 12, weight: .medium),
                    .foregroundColor: bookSecondaryLabelColor,
                    .paragraphStyle: metaStyle,
                ]
            ),
            in: CGRect(x: 70, y: 345, width: pageRect.width - 140, height: 110),
            context: context
        )

        let contents = document.sections.prefix(8).map {
            "Раздел \($0.index + 1)     \(TranscriptExportPolicy.timestamp($0.startTime))"
        }.joined(separator: "\n")
        drawText(
            NSAttributedString(
                string: "Оглавление\n\(contents)",
                attributes: [
                    .font: BookFont.systemFont(ofSize: 11, weight: .medium),
                    .foregroundColor: bookLabelColor,
                ]
            ),
            in: CGRect(x: 70, y: 192, width: pageRect.width - 140, height: 125),
            context: context
        )

        let sourceRect = CGRect(x: 70, y: 142, width: pageRect.width - 140, height: 30)
        drawText(
            NSAttributedString(
                string: "Открыть исходное видео",
                attributes: [
                    .font: BookFont.systemFont(ofSize: 10.5, weight: .semibold),
                    .foregroundColor: bookAccentColor,
                ]
            ),
            in: sourceRect,
            context: context
        )
        context.setURL(document.metadata.videoURL as CFURL, for: sourceRect)
        context.endPDFPage()
    }

    private func drawText(_ text: NSAttributedString, in rect: CGRect, context: CGContext) {
        let framesetter = CTFramesetterCreateWithAttributedString(text)
        let frame = CTFramesetterCreateFrame(
            framesetter,
            CFRange(location: 0, length: text.length),
            CGPath(rect: rect, transform: nil),
            nil
        )
        CTFrameDraw(frame, context)
    }

    private func makeAttributedBody(_ document: TranscriptBookDocument) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "")
        append(
            "Оглавление",
            to: result,
            font: BookFont.systemFont(ofSize: 23, weight: .bold),
            color: bookLabelColor,
            spacingAfter: 12
        )
        for section in document.sections {
            append(
                "Раздел \(section.index + 1)   \(TranscriptExportPolicy.timestamp(section.startTime))",
                to: result,
                font: BookFont.systemFont(ofSize: 11.5, weight: .medium),
                color: bookAccentColor,
                spacingAfter: 6
            )
        }
        append("", to: result, font: BookFont.systemFont(ofSize: 8), spacingAfter: 18)

        for section in document.sections {
            append(
                "Раздел \(section.index + 1)   \(TranscriptExportPolicy.timestamp(section.startTime))",
                to: result,
                font: BookFont.systemFont(ofSize: 19, weight: .semibold),
                color: bookAccentColor,
                spacingBefore: 16,
                spacingAfter: 11
            )
            for paragraph in section.paragraphs {
                append(
                    TranscriptExportPolicy.timestamp(paragraph.startTime),
                    to: result,
                    font: BookFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .semibold),
                    color: bookSecondaryLabelColor,
                    spacingAfter: 4
                )
                append(
                    paragraph.text,
                    to: result,
                    font: BookFont.systemFont(ofSize: 12.2),
                    color: bookLabelColor,
                    lineSpacing: 4.2,
                    spacingAfter: 13
                )
            }
        }
        append(
            "Исходное видео\n\(document.metadata.videoURL.absoluteString)",
            to: result,
            font: BookFont.systemFont(ofSize: 10.5, weight: .medium),
            color: bookSecondaryLabelColor,
            spacingBefore: 20,
            spacingAfter: 8
        )
        return result
    }

    private func append(
        _ text: String,
        to result: NSMutableAttributedString,
        font: BookFont,
        color: BookColor = bookLabelColor,
        lineSpacing: CGFloat = 0,
        spacingBefore: CGFloat = 0,
        spacingAfter: CGFloat = 0
    ) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing
        paragraph.paragraphSpacingBefore = spacingBefore
        paragraph.paragraphSpacing = spacingAfter
        paragraph.lineBreakMode = .byWordWrapping
        result.append(NSAttributedString(
            string: text + "\n",
            attributes: [
                .font: font,
                .foregroundColor: color,
                .paragraphStyle: paragraph,
            ]
        ))
    }

    private func drawHeader(
        document: TranscriptBookDocument,
        pageNumber: Int,
        context: CGContext
    ) {
        let header = NSAttributedString(
            string: "AxrTube   \(document.metadata.title)",
            attributes: [
                .font: BookFont.systemFont(ofSize: 8.5, weight: .medium),
                .foregroundColor: bookSecondaryLabelColor,
            ]
        )
        context.textPosition = CGPoint(x: horizontalMargin, y: pageRect.height - 40)
        CTLineDraw(CTLineCreateWithAttributedString(header), context)

        let footer = NSAttributedString(
            string: "Страница \(pageNumber)   ·   \(document.metadata.videoURL.absoluteString)",
            attributes: [
                .font: BookFont.systemFont(ofSize: 8),
                .foregroundColor: bookSecondaryLabelColor,
            ]
        )
        context.textPosition = CGPoint(x: horizontalMargin, y: 31)
        CTLineDraw(CTLineCreateWithAttributedString(footer), context)
    }
}

actor TranscriptBookService {
    typealias PDFRenderer = @Sendable (TranscriptBookDocument, URL) throws -> Int

    private struct Manifest: Codable, Equatable {
        let formatterVersion: Int
        let cacheKey: String
        let pageCount: Int
        let document: TranscriptBookDocument
    }

    private let fileManager: FileManager
    private let baseDirectory: URL
    private let pdfRenderer: PDFRenderer

    init(
        baseDirectory: URL? = nil,
        fileManager: FileManager = .default,
        pdfRenderer: @escaping PDFRenderer = { document, url in
            try TranscriptBookPDFRenderer().render(document: document, to: url)
        }
    ) {
        self.fileManager = fileManager
        self.baseDirectory = baseDirectory ?? fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("AxrTube/TranscriptBooks", isDirectory: true)
        self.pdfRenderer = pdfRenderer
    }

    func prepare(_ request: TranscriptBookRequest) throws -> TranscriptBookResult {
        let candidate = try TranscriptBookPolicy.makeDocument(request: request)
        try fileManager.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        try cleanupStagingDirectories()
        let finalDirectory = baseDirectory.appendingPathComponent(candidate.cacheKey, isDirectory: true)
        if !request.forceRebuild, let cached = try cachedResult(at: finalDirectory, key: candidate.cacheKey) {
            return cached
        }

        let staging = baseDirectory.appendingPathComponent(
            ".staging-\(candidate.cacheKey)-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        do {
            let markdownURL = staging.appendingPathComponent(candidate.safeBaseFilename)
                .appendingPathExtension("md")
            let htmlURL = staging.appendingPathComponent(candidate.safeBaseFilename)
                .appendingPathExtension("html")
            let pdfURL = staging.appendingPathComponent(candidate.safeBaseFilename)
                .appendingPathExtension("pdf")
            let manifestURL = staging.appendingPathComponent("manifest.json")
            try Data(candidate.markdown.utf8).write(to: markdownURL, options: .atomic)
            try Data(candidate.html.utf8).write(to: htmlURL, options: .atomic)
            let pageCount = try pdfRenderer(candidate, pdfURL)
            let pdfValues = try? pdfURL.resourceValues(forKeys: [.fileSizeKey])
            let pdfSize = pdfValues?.fileSize ?? 0
            guard pageCount > 0, pdfSize > 0 else {
                throw TranscriptBookFailure.exportFailed
            }
            let manifest = Manifest(
                formatterVersion: TranscriptBookPolicy.formatterVersion,
                cacheKey: candidate.cacheKey,
                pageCount: pageCount,
                document: candidate
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(manifest).write(to: manifestURL, options: .atomic)

            if fileManager.fileExists(atPath: finalDirectory.path) {
                _ = try fileManager.replaceItemAt(
                    finalDirectory,
                    withItemAt: staging,
                    backupItemName: nil,
                    options: [.usingNewMetadataOnly]
                )
            } else {
                try fileManager.moveItem(at: staging, to: finalDirectory)
            }
            guard let result = try cachedResult(at: finalDirectory, key: candidate.cacheKey) else {
                throw TranscriptBookFailure.exportFailed
            }
            return TranscriptBookResult(
                document: result.document,
                artifacts: result.artifacts,
                wasCached: false
            )
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }
    }

    private func cachedResult(at directory: URL, key: String) throws -> TranscriptBookResult? {
        let manifestURL = directory.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
              manifest.formatterVersion == TranscriptBookPolicy.formatterVersion,
              manifest.cacheKey == key else { return nil }
        let markdownURL = directory.appendingPathComponent(manifest.document.safeBaseFilename)
            .appendingPathExtension("md")
        let htmlURL = directory.appendingPathComponent(manifest.document.safeBaseFilename)
            .appendingPathExtension("html")
        let pdfURL = directory.appendingPathComponent(manifest.document.safeBaseFilename)
            .appendingPathExtension("pdf")
        let pdfValues = try? pdfURL.resourceValues(forKeys: [.fileSizeKey])
        guard let markdownData = try? Data(contentsOf: markdownURL),
              !markdownData.isEmpty,
              String(data: markdownData, encoding: .utf8) != nil,
              let htmlData = try? Data(contentsOf: htmlURL),
              !htmlData.isEmpty,
              String(data: htmlData, encoding: .utf8) != nil,
              (pdfValues?.fileSize ?? 0) > 0 else { return nil }
        return TranscriptBookResult(
            document: manifest.document,
            artifacts: TranscriptBookArtifacts(
                markdownURL: markdownURL,
                htmlURL: htmlURL,
                pdfURL: pdfURL,
                pageCount: manifest.pageCount
            ),
            wasCached: true
        )
    }

    private func cleanupStagingDirectories() throws {
        let contents = try fileManager.contentsOfDirectory(
            at: baseDirectory,
            includingPropertiesForKeys: nil
        )
        for url in contents where url.lastPathComponent.hasPrefix(".staging-") {
            try? fileManager.removeItem(at: url)
        }
    }
}

enum TranscriptBookFileFormat: String, CaseIterable, Sendable {
    case markdown
    case html
    case pdf

    var fileExtension: String {
        switch self {
        case .markdown: "md"
        case .html: "html"
        case .pdf: "pdf"
        }
    }
}

struct TranscriptBookExportPayload: Equatable, Sendable {
    let format: TranscriptBookFileFormat
    let filename: String
    let data: Data
}

enum TranscriptBookFileExportPolicy {
    static func payload(
        from artifacts: TranscriptBookArtifacts,
        format: TranscriptBookFileFormat
    ) throws -> TranscriptBookExportPayload {
        let sourceURL: URL
        switch format {
        case .markdown: sourceURL = artifacts.markdownURL
        case .html: sourceURL = artifacts.htmlURL
        case .pdf: sourceURL = artifacts.pdfURL
        }
        let data = try Data(contentsOf: sourceURL, options: [.mappedIfSafe])
        guard !data.isEmpty else { throw TranscriptBookFailure.exportFailed }
        let filename = sourceURL.lastPathComponent
        guard sourceURL.pathExtension.lowercased() == format.fileExtension else {
            throw TranscriptBookFailure.exportFailed
        }
        return TranscriptBookExportPayload(
            format: format,
            filename: filename,
            data: data
        )
    }
}
