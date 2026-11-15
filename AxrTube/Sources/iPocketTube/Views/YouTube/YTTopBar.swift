#if os(iOS)
import SwiftUI
import UIKit

/// YouTube iOS header: logo, then cast (AirPlay), search and, on the "Вы"
/// tab only, the settings gear.
struct YTTopBar: View {
    let onSearch: () -> Void
    var onSettings: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 2) {
            YTLogo()
            Spacer()
            AirPlayRoutePickerView(tint: UIColor(YTColor.primaryText))
                .frame(width: 44, height: 44)
                .accessibilityLabel("Трансляция")
            iconButton("magnifyingglass", label: "Поиск", id: "topbar.search", action: onSearch)
            if let onSettings {
                iconButton("gearshape", label: "Настройки", id: "topbar.settings", action: onSettings)
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 4)
        .frame(height: 48)
        .background(YTColor.background)
    }

    private func iconButton(_ symbol: String, label: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(YTColor.primaryText)
                .frame(width: 44, height: 44)
        }
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }
}

/// Red play badge + wordmark, drawn natively so it scales with Dynamic Type.
struct YTLogo: View {
    var body: some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(YTColor.brandRed)
                .frame(width: 30, height: 21)
                .overlay {
                    Image(systemName: "play.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                }
            Text("AxrTube")
                .font(.system(size: 21, weight: .bold))
                .tracking(-1)
                .foregroundStyle(YTColor.primaryText)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("AxrTube")
    }
}
#endif
