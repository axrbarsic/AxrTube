#if os(iOS)
import SwiftUI
import iPocketTubeCore

extension Notification.Name {
    /// Posted with the tab's raw value when the already selected tab is tapped.
    static let ytTabReselected = Notification.Name("com.axrtube.ytTabReselected")
}

/// YouTube's horizontal Shorts shelf inside a feed.
struct YTShortsShelf: View {
    let videos: [Video]
    let onSelect: (Video) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "play.square.stack.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(YTColor.brandRed)
                Text("Shorts").font(.system(size: 18, weight: .bold))
            }
            .foregroundStyle(YTColor.primaryText)
            .padding(.horizontal, 12)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 8) {
                    ForEach(videos) { video in
                        Button { onSelect(video) } label: { tile(video) }
                            .buttonStyle(YTPressStyle())
                            .accessibilityIdentifier("shorts.tile.\(video.id)")
                    }
                }
                .padding(.horizontal, 12)
            }
        }
        .padding(.vertical, 14)
        .overlay(alignment: .bottom) { Rectangle().fill(YTColor.chip).frame(height: 4) }
        .padding(.bottom, 12)
    }

    private func tile(_ video: Video) -> some View {
        ThumbnailFillView(primaryURL: video.thumbnailURL, fallbackURLs: video.thumbnailFallbackURLs)
            .frame(width: 168, height: 298)
            .background(YTColor.placeholder)
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(video.title)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if let views = video.viewCount {
                        Text(YouTubeMetaFormatter.views(views)).font(.system(size: 12))
                    }
                }
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.7), radius: 3)
                .padding(8)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// The Shorts tab: the Shorts feed in the vertical pager, with continuation.
struct YTShortsTabView: View {
    @State private var vm: BrowseViewModel
    @Environment(AuthService.self) private var auth

    init(api: InnerTubeAPI) {
        _vm = State(initialValue: BrowseViewModel(api: api, initialSection: BrowseSection(type: .shorts)))
    }

    private var videos: [Video] {
        var seen = Set<String>()
        return vm.videoGroups.flatMap(\.videos).filter { seen.insert($0.id).inserted }
    }

    var body: some View {
        Group {
            if videos.isEmpty && vm.isLoading {
                ProgressView().tint(.white).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if videos.isEmpty {
                YTFeedMessage(title: "Не удалось загрузить Shorts", actionTitle: "Повторить") {
                    vm.loadContent(for: BrowseSection(type: .shorts), refresh: true, source: "yt-shorts.retry")
                }
            } else {
                YTShortsPager(videos: videos, onNearEnd: {
                    if let last = videos.last { vm.loadMoreIfNeeded(lastVideo: last) }
                })
            }
        }
        .background(Color.black)
        .task(id: auth.authSnapshot) {
            await vm.applyAuthSnapshot(auth.authSnapshot)
            if videos.isEmpty { vm.loadContent(for: BrowseSection(type: .shorts), source: "yt-shorts") }
        }
    }
}
#endif
