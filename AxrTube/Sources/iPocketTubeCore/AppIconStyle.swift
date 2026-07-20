import Foundation

/// User-selectable app icon variants exposed by the iOS application target.
public enum AppIconStyle: String, CaseIterable, Codable, Sendable {
    case red
    case green

    public static let greenAlternateIconName = "AppIconGreen"

    public init(alternateIconName: String?) {
        self = alternateIconName == Self.greenAlternateIconName ? .green : .red
    }

    public var alternateIconName: String? {
        switch self {
        case .red: nil
        case .green: Self.greenAlternateIconName
        }
    }
}
