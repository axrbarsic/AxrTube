import SwiftUI
import SmartTubeIOSCore

/// One publication-date presentation shared by search, feeds, channels,
/// history, subscriptions and playlists through `VideoCardView`.
struct VideoPublicationLabel: View {
    let video: Video

    var body: some View {
        Label {
            Text(VideoPublicationFormatter.string(for: video))
        } icon: {
            Image(systemName: "calendar")
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(SmartTubeVisualTokens.mintSoft)
        .padding(.top, 2)
        .accessibilityLabel(
            Text("Publication date: \(VideoPublicationFormatter.string(for: video))")
        )
        .accessibilityIdentifier("video.card.publicationDate")
    }
}
