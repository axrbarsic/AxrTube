import SwiftUI
import iPocketTubeCore

// MARK: - ManageRSSFeedsView

/// Sheet showing the list of saved RSS feeds with toggle-active and swipe-to-delete.

struct ManageRSSFeedsView: View {
    @State private var feeds: [RSSFeedInfo] = []
    @State private var isLoading = true
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if feeds.isEmpty {
                    ContentUnavailableView(
                        "No RSS Feeds",
                        systemImage: "dot.radiowaves.left.and.right",
                        description: Text("Add a feed from the RSS Feeds screen.")
                    )
                } else {
                    List {
                        ForEach(feeds) { feed in
                            feedRow(feed)
                        }
                        .onDelete(perform: deleteFeeds)
                    }
                }
            }
            .navigationTitle("Manage RSS Feeds")
#if !os(macOS) && !os(tvOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                await reloadFeeds()
            }
        }
    }

    private func feedRow(_ feed: RSSFeedInfo) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(feed.title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                Text(feed.feedURL.absoluteString)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { feed.isActive },
                set: { newValue in
                    Task {
                        await RSSFeedStore.shared.setActive(feed.id, newValue)
                        await reloadFeeds()
                    }
                }
            ))
            .labelsHidden()
        }
        .padding(.vertical, 2)
    }

    private func deleteFeeds(at offsets: IndexSet) {
        let toDelete = offsets.map { feeds[$0] }
        Task {
            for feed in toDelete {
                await RSSFeedStore.shared.removeFeed(id: feed.id)
            }
            await reloadFeeds()
        }
    }

    @MainActor
    private func reloadFeeds() async {
        feeds = await RSSFeedStore.shared.allFeeds()
        isLoading = false
    }
}
