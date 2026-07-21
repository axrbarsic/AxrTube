import Foundation

/// The two supported ways to color the signed AxrTube icon variants.
public enum AppIconColorTarget: String, CaseIterable, Codable, Sendable {
    case background
    case glyph
}

/// User-selectable app icon variants exposed by the iOS application target.
///
/// iOS only accepts alternate icons compiled into the signed application bundle.
/// Keeping every choice in this single enum makes the system icon name the sole
/// persisted owner and prevents the settings preview from drifting from SpringBoard.
public enum AppIconStyle: String, CaseIterable, Codable, Sendable {
    case red
    case green
    case blue
    case orange
    case purple
    case pink
    case yellow
    case white
    case black

    case glyphRed
    case glyphGreen
    case glyphBlue
    case glyphOrange
    case glyphPurple
    case glyphPink
    case glyphYellow
    case glyphWhite
    case glyphBlack

    public init(alternateIconName: String?) {
        guard let alternateIconName,
              let style = Self.allCases.first(where: { $0.alternateIconName == alternateIconName }) else {
            self = .red
            return
        }
        self = style
    }

    public var alternateIconName: String? {
        switch self {
        case .red: nil
        case .green: "AppIconGreen"
        case .blue: "AppIconBlue"
        case .orange: "AppIconOrange"
        case .purple: "AppIconPurple"
        case .pink: "AppIconPink"
        case .yellow: "AppIconYellow"
        case .white: "AppIconWhite"
        case .black: "AppIconBlack"
        case .glyphRed: "AppIconGlyphRed"
        case .glyphGreen: "AppIconGlyphGreen"
        case .glyphBlue: "AppIconGlyphBlue"
        case .glyphOrange: "AppIconGlyphOrange"
        case .glyphPurple: "AppIconGlyphPurple"
        case .glyphPink: "AppIconGlyphPink"
        case .glyphYellow: "AppIconGlyphYellow"
        case .glyphWhite: "AppIconGlyphWhite"
        case .glyphBlack: "AppIconGlyphBlack"
        }
    }

    public var colorTarget: AppIconColorTarget {
        switch self {
        case .red, .green, .blue, .orange, .purple, .pink, .yellow, .white, .black:
            .background
        case .glyphRed, .glyphGreen, .glyphBlue, .glyphOrange, .glyphPurple,
             .glyphPink, .glyphYellow, .glyphWhite, .glyphBlack:
            .glyph
        }
    }

    public var colorName: String {
        switch self {
        case .red, .glyphRed: "Красный"
        case .green, .glyphGreen: "Зелёный"
        case .blue, .glyphBlue: "Голубой"
        case .orange, .glyphOrange: "Оранжевый"
        case .purple, .glyphPurple: "Фиолетовый"
        case .pink, .glyphPink: "Розовый"
        case .yellow, .glyphYellow: "Жёлтый"
        case .white, .glyphWhite: "Белый"
        case .black, .glyphBlack: "Чёрный"
        }
    }

    public var previewAssetName: String {
        "AppIconPreview-\(rawValue)"
    }

    public static func styles(for target: AppIconColorTarget) -> [AppIconStyle] {
        allCases.filter { $0.colorTarget == target }
    }
}
