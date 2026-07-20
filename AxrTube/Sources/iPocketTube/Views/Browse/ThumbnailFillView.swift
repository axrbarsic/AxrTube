import SwiftUI

// MARK: - ThumbnailFillView
//
// Loads a thumbnail URL and fills its frame with the image, cropped to fit
// (scaledToFill + clipped). Falls back through `fallbackURLs` on load error.
//
// Uses GeometryReader to give AsyncImage explicit pixel dimensions so that
// scaledToFill is always constrained to exactly the offered frame — the only
// reliable way to prevent SwiftUI layout bleed with fill-mode images.

struct ThumbnailFillView: View {
    /// Primary URL to try first.
    let primaryURL: URL?
    /// Ordered fallbacks tried after `primaryURL` fails.
    var fallbackURLs: [URL] = []

    @State private var fallbackIndex: Int = -1

    private var activeURL: URL? {
        if fallbackIndex < 0 { return primaryURL }
        guard fallbackIndex < fallbackURLs.count else { return nil }
        return fallbackURLs[fallbackIndex]
    }

    var body: some View {
        GeometryReader { geo in
            AsyncImage(url: activeURL) { phase in
                switch phase {
                case .success(let img):
                    img.resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                case .failure:
                    let next = fallbackIndex < 0 ? 0 : fallbackIndex + 1
                    Color.secondary.opacity(0.15)
                        .onAppear {
                            if next < fallbackURLs.count { fallbackIndex = next }
                        }
                default:
                    Color.secondary.opacity(0.15)
                        .overlay { ProgressView().tint(.white) }
                }
            }
        }
        // Reset fallback chain when the primary URL changes (new video reused in cell).
        .task(id: primaryURL) { fallbackIndex = -1 }
    }
}
