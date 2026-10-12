#if os(iOS)
import SwiftUI

/// YouTube iOS top bar: logo on the left, search on the right.
struct YTTopBar: View {
    var title: String? = nil
    let onSearch: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            if let title {
                Text(title)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(YTColor.primaryText)
            } else {
                YTLogo()
            }
            Spacer()
            Button(action: onSearch) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 20, weight: .regular))
                    .foregroundStyle(YTColor.primaryText)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Поиск")
            .accessibilityIdentifier("topbar.search")
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .frame(height: 48)
        .background(YTColor.background)
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
                .font(.system(size: 20, weight: .bold))
                .tracking(-0.6)
                .foregroundStyle(YTColor.primaryText)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("AxrTube")
    }
}
#endif
