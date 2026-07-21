import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

private struct RGB: Sendable {
    let red: Double
    let green: Double
    let blue: Double

    init(_ red: Double, _ green: Double, _ blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }
}

private struct Variant: Sendable {
    let rawValue: String
    let assetName: String?
    let background: RGB
    let glyph: RGB
    let existingSource: String?
}

private let red = RGB(0.92, 0.01, 0.01)
private let green = RGB(0.00, 0.68, 0.08)
private let blue = RGB(0.02, 0.44, 0.96)
private let orange = RGB(1.00, 0.36, 0.01)
private let purple = RGB(0.49, 0.20, 0.92)
private let pink = RGB(1.00, 0.16, 0.54)
private let yellow = RGB(1.00, 0.78, 0.00)
private let white = RGB(0.98, 0.98, 0.99)
private let black = RGB(0.025, 0.025, 0.03)

private let variants: [Variant] = [
    Variant(rawValue: "red", assetName: nil, background: red, glyph: white, existingSource: "AppIcon.appiconset/icon-1024.png"),
    Variant(rawValue: "green", assetName: "AppIconGreen", background: green, glyph: white, existingSource: "AppIconGreen.appiconset/icon-1024.png"),
    Variant(rawValue: "blue", assetName: "AppIconBlue", background: blue, glyph: white, existingSource: nil),
    Variant(rawValue: "orange", assetName: "AppIconOrange", background: orange, glyph: white, existingSource: nil),
    Variant(rawValue: "purple", assetName: "AppIconPurple", background: purple, glyph: white, existingSource: nil),
    Variant(rawValue: "pink", assetName: "AppIconPink", background: pink, glyph: white, existingSource: nil),
    Variant(rawValue: "yellow", assetName: "AppIconYellow", background: yellow, glyph: black, existingSource: nil),
    Variant(rawValue: "white", assetName: "AppIconWhite", background: white, glyph: black, existingSource: nil),
    Variant(rawValue: "black", assetName: "AppIconBlack", background: black, glyph: white, existingSource: nil),
    Variant(rawValue: "glyphRed", assetName: "AppIconGlyphRed", background: white, glyph: red, existingSource: nil),
    Variant(rawValue: "glyphGreen", assetName: "AppIconGlyphGreen", background: black, glyph: green, existingSource: nil),
    Variant(rawValue: "glyphBlue", assetName: "AppIconGlyphBlue", background: white, glyph: blue, existingSource: nil),
    Variant(rawValue: "glyphOrange", assetName: "AppIconGlyphOrange", background: black, glyph: orange, existingSource: nil),
    Variant(rawValue: "glyphPurple", assetName: "AppIconGlyphPurple", background: white, glyph: purple, existingSource: nil),
    Variant(rawValue: "glyphPink", assetName: "AppIconGlyphPink", background: black, glyph: pink, existingSource: nil),
    Variant(rawValue: "glyphYellow", assetName: "AppIconGlyphYellow", background: black, glyph: yellow, existingSource: nil),
    Variant(rawValue: "glyphWhite", assetName: "AppIconGlyphWhite", background: black, glyph: white, existingSource: nil),
    Variant(rawValue: "glyphBlack", assetName: "AppIconGlyphBlack", background: white, glyph: black, existingSource: nil),
]

private func loadImage(at url: URL) throws -> CGImage {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        throw CocoaError(.fileReadCorruptFile)
    }
    return image
}

private func writePNG(_ image: CGImage, to url: URL) throws {
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL,
        UTType.png.identifier as CFString,
        1,
        nil
    ) else {
        throw CocoaError(.fileWriteUnknown)
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw CocoaError(.fileWriteUnknown)
    }
}

private func smoothstep(_ lower: Double, _ upper: Double, _ value: Double) -> Double {
    let normalized = max(0, min(1, (value - lower) / (upper - lower)))
    return normalized * normalized * (3 - 2 * normalized)
}

private func renderVariant(source: CGImage, background: RGB, glyph: RGB) throws -> CGImage {
    let width = source.width
    let height = source.height
    let bytesPerRow = width * 4
    var sourcePixels = [UInt8](repeating: 0, count: height * bytesPerRow)

    guard let sourceContext = CGContext(
        data: &sourcePixels,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: bytesPerRow,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
    ) else {
        throw CocoaError(.coderInvalidValue)
    }
    sourceContext.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))

    var outputPixels = sourcePixels
    for pixelOffset in stride(from: 0, to: sourcePixels.count, by: 4) {
        let sourceRed = Double(sourcePixels[pixelOffset]) / 255
        let sourceGreen = Double(sourcePixels[pixelOffset + 1]) / 255
        let sourceBlue = Double(sourcePixels[pixelOffset + 2]) / 255
        let whiteness = min(sourceRed, min(sourceGreen, sourceBlue))
        let glyphMask = smoothstep(0.66, 0.94, whiteness)

        // The red channel contains the original gradient and the AXR drop shadow.
        // Reusing it preserves the established dimensionality for every color.
        let backgroundShade = 0.58 + (0.42 * sourceRed)
        let glyphShade = 0.90 + (0.10 * max(sourceRed, max(sourceGreen, sourceBlue)))

        let backgroundComponents = [
            background.red * backgroundShade,
            background.green * backgroundShade,
            background.blue * backgroundShade,
        ]
        let glyphComponents = [
            glyph.red * glyphShade,
            glyph.green * glyphShade,
            glyph.blue * glyphShade,
        ]

        for component in 0..<3 {
            let value = backgroundComponents[component] * (1 - glyphMask)
                + glyphComponents[component] * glyphMask
            outputPixels[pixelOffset + component] = UInt8(max(0, min(255, value * 255)).rounded())
        }
        outputPixels[pixelOffset + 3] = 255
    }

    guard let outputContext = CGContext(
        data: &outputPixels,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: bytesPerRow,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
    ), let image = outputContext.makeImage() else {
        throw CocoaError(.coderInvalidValue)
    }
    return image
}

private func resize(_ image: CGImage, side: Int) throws -> CGImage {
    guard let context = CGContext(
        data: nil,
        width: side,
        height: side,
        bitsPerComponent: 8,
        bytesPerRow: side * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
    ) else {
        throw CocoaError(.coderInvalidValue)
    }
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
    guard let resized = context.makeImage() else {
        throw CocoaError(.coderInvalidValue)
    }
    return resized
}

private let appIconContents = """
{
  "images" : [
    {
      "filename" : "icon-1024.png",
      "idiom" : "universal",
      "platform" : "ios",
      "scale" : "1x",
      "size" : "1024x1024"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
"""

let repositoryRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let assetCatalog = repositoryRoot.appending(path: "AxrTubeApp/iPocketTubeApp/Assets.xcassets")
let primarySourceURL = assetCatalog.appending(path: "AppIcon.appiconset/icon-1024.png")
let primarySource = try loadImage(at: primarySourceURL)
let previewDirectory = repositoryRoot.appending(path: "AxrTube/Sources/iPocketTube/Resources/AppIconPreviews")
try FileManager.default.createDirectory(at: previewDirectory, withIntermediateDirectories: true)

for variant in variants {
    let rendered: CGImage
    if let existingSource = variant.existingSource {
        rendered = try loadImage(at: assetCatalog.appending(path: existingSource))
    } else {
        rendered = try renderVariant(source: primarySource, background: variant.background, glyph: variant.glyph)
        guard let assetName = variant.assetName else {
            fatalError("Only the primary red icon may omit an alternate asset name")
        }
        let appIconDirectory = assetCatalog.appending(path: "\(assetName).appiconset")
        try FileManager.default.createDirectory(at: appIconDirectory, withIntermediateDirectories: true)
        try writePNG(rendered, to: appIconDirectory.appending(path: "icon-1024.png"))
        try appIconContents.write(
            to: appIconDirectory.appending(path: "Contents.json"),
            atomically: true,
            encoding: .utf8
        )
    }

    let preview = try resize(rendered, side: 320)
    try writePNG(
        preview,
        to: previewDirectory.appending(path: "AppIconPreview-\(variant.rawValue).png")
    )
}

print("Generated \(variants.count) signed icon previews and \(variants.count - 2) new alternate icon assets.")
