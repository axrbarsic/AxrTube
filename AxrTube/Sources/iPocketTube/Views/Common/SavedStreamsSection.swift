#if os(iOS)
import SwiftUI
import iPocketTubeCore

/// Videos saved with «Скачать» from the stream cache, shown at the top of
/// «Скачанные». Tap plays (offline from disk), swipe deletes.
struct SavedStreamsSection: View {
    let onPlay: (Video) -> Void
    @State private var library = PinnedStreamLibrary.shared

    var body: some View {
        ForEach(library.entries) { entry in
            Button { onPlay(entry.video) } label: { row(entry) }
                .buttonStyle(.plain)
                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) { SavedStreamService.shared.remove(entry.videoId) } label: {
                        Label("Удалить", systemImage: "trash")
                    }
                }
                .accessibilityIdentifier("downloads.saved.\(entry.videoId)")
        }
    }

    private func row(_ entry: PinnedStream) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ThumbnailFillView(primaryURL: entry.thumbnailURL, fallbackURLs: [])
                .frame(width: 160, height: 90)
                .background(YTColor.placeholder)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(alignment: .bottom) {
                    if !entry.isComplete {
                        GeometryReader { geo in
                            Rectangle().fill(YTProgressLayers.cacheColor)
                                .frame(width: geo.size.width * entry.progress, height: 4)
                                .frame(maxHeight: .infinity, alignment: .bottom)
                        }
                    }
                }
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(YTColor.primaryText)
                    .lineLimit(2)
                Text(entry.channelTitle)
                    .font(.system(size: 12))
                    .foregroundStyle(YTColor.secondaryText)
                    .lineLimit(1)
                Label(status(entry), systemImage: entry.isComplete ? "checkmark.circle.fill" : "arrow.down.circle")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(entry.isComplete ? YTProgressLayers.cacheColor : YTColor.secondaryText)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }

    private func status(_ entry: PinnedStream) -> String {
        let size = ByteCountFormatter.string(fromByteCount: entry.bytes, countStyle: .file)
        return entry.isComplete ? "Скачано · \(size)" : "Скачивается · \(Int(entry.progress * 100))%"
    }
}
#endif
