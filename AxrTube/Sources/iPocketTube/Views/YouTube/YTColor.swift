#if os(iOS)
import SwiftUI
import UIKit

/// YouTube iOS palette. Every token resolves for dark and light appearance.
enum YTColor {
    static let background = adaptive(dark: 0x0F0F0F, light: 0xFFFFFF)
    static let elevated = adaptive(dark: 0x212121, light: 0xFFFFFF)
    static let chip = adaptive(dark: 0x272727, light: 0xF2F2F2)
    static let chipSelected = adaptive(dark: 0xF1F1F1, light: 0x0F0F0F)
    static let chipSelectedText = adaptive(dark: 0x0F0F0F, light: 0xFFFFFF)
    static let primaryText = adaptive(dark: 0xF1F1F1, light: 0x0F0F0F)
    static let secondaryText = adaptive(dark: 0xAAAAAA, light: 0x606060)
    static let placeholder = adaptive(dark: 0x272727, light: 0xE5E5E5)
    static let divider = adaptive(dark: 0x3F3F3F, light: 0xE5E5E5)
    static let brandRed = Color(hex: 0xFF0000)
    static let liveRed = Color(hex: 0xCC0000)

    private static let avatarPalette: [Color] = [
        0x5E35B1, 0x00897B, 0xD81B60, 0x3949AB, 0xF4511E, 0x7CB342, 0x8E24AA, 0x039BE5,
    ].map { Color(hex: $0) }

    /// Stable per-channel colour for the letter avatar.
    static func avatarFill(for title: String) -> Color {
        let sum = title.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return avatarPalette[abs(sum) % avatarPalette.count]
    }

    private static func adaptive(dark: UInt32, light: UInt32) -> Color {
        Color(UIColor { traits in
            UIColor(hex: traits.userInterfaceStyle == .dark ? dark : light)
        })
    }
}

private extension UIColor {
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}
#endif
