import SwiftUI
import iPocketTubeCore
import os

private let focusLog = Logger(subsystem: "com.ipockettube", category: "focus")
private let feedLog  = Logger(subsystem: "com.ipockettube", category: "feed")

// MARK: - Notification names

extension Notification.Name {
    /// Posted when the user selects "Open Channel" from a video's context menu.
    /// userInfo keys: "channelId", "channelTitle"
    static let openChannel = Notification.Name("com.ipockettube.openChannel")
    /// Posted when a feature requests navigation to the Search tab (e.g. empty-state CTA).
    static let navigateToSearch = Notification.Name("com.ipockettube.navigateToSearch")
    // hideVideoFromFeed and hideChannelFromFeed are defined in iPocketTubeCore/FeedFeedbackNotifications.swift
}

// MARK: - VideoCardView
//
// A card showing a video thumbnail, title, channel and metadata.
// Adapts its layout for list (compact) and grid (default) modes.

public struct VideoCardView: View {
    public let video: Video
    public var compact: Bool = false
    /// When set, this is the `playlistId` of the list the user is currently browsing.
    /// Pass `"WL"` when inside the Watch Later playlist so the context menu shows
    /// "Remove from Watch Later" instead of "Save to Watch Later".
    public var currentPlaylistId: String? = nil
    /// Called when the user taps/selects the card on tvOS (via `.onTapGesture`).
    /// iOS call sites continue using their own tap handlers; this is only invoked
    /// from the `#else` (tvOS) modifier block below.
    public var onSelect: (() -> Void)? = nil

    @Environment(AuthService.self) private var authService
    @Environment(SettingsStore.self) private var store
    @Environment(\.innerTubeAPI) private var api
    @State private var localProgress: Double?
    @State private var watchLaterAlert: DownloadAlertItem?
    /// Index into `video.thumbnailFallbackURLs`. -1 = use primary `thumbnailURL`.
    @State private var thumbnailFallbackIndex: Int = -1
    #if !os(tvOS)
    @Environment(VideoDownloadService.self) private var downloadService
    #endif
    #if os(tvOS)
    @FocusState private var isFocused: Bool
    #endif

    private var effectiveProgress: Double? {
        localProgress ?? video.watchProgress
    }

    public init(video: Video, compact: Bool = false, currentPlaylistId: String? = nil, onSelect: (() -> Void)? = nil) {
        self.video = video
        self.compact = compact
        self.currentPlaylistId = currentPlaylistId
        self.onSelect = onSelect
    }

    // MARK: - Shared card content (tasks + context menu)
    // Extracted so the tvOS body can wrap it in a Button (which handles the
    // Select button press natively) while iOS continues using the bare view.

    private var cardContent: some View {
        selectedLayout
        .task {
            localProgress = await VideoStateStore.shared.state(for: video.id)?.watchedFraction
        }
        .task(id: video.id) {
            await VideoPreloadCache.shared.prefetch(
                videoId: video.id,
                sponsorCategories: store.settings.activeSponsorCategories,
                authToken: authService.accessToken,
                priority: .visible
            )
            // Pre-warm BotGuardWebViewRunner when cards scroll into view so the
            // WKWebView youtube.com context is ready before the user taps. Only
            // runs once — isReady short-circuits all subsequent calls (~0ms).
            // fix16: Await BotGuard BEFORE preWarm so its SOCS cookie is in the shared
            // .default() WKWebView data store before extractHLSURL creates its WKWebView.
            // Without this, uN7uKLsGRWw (rqh=1) hits a GDPR redirect on a cold data store
            // and times out at 40 s. With the SOCS cookie already set, extraction is ~2 s.
            // BotGuard.prepare() is idempotent (no-op if already ready, or coalescences with
            // an ongoing task), so all card tasks joining the same prepare() call pay ≤8 s
            // total — not per-card.
            #if canImport(WebKit)
            await BotGuardWebViewRunner.shared.prepare()
            // iOS uses TOS player (WKWebView embed) by default — HLS URLs are never
            // consumed there, so pre-warming the HLS extractor is pure waste and the
            // primary source of the SlowLoad NON_FATAL (4497ms per card on scroll).
            // Mac/tvOS still use AVPlayer and need the pre-warm.
            #if !os(iOS)
            if !video.isShort &&
               YouTubeWebViewHLSExtractor.activePreWarmLoops < YouTubeWebViewHLSExtractor.maxPreWarmLoops {
                YouTubeWebViewHLSExtractor.activePreWarmLoops += 1
                defer { YouTubeWebViewHLSExtractor.activePreWarmLoops -= 1 }
                let videoId = video.id
                outer: while !Task.isCancelled {
                    if await VideoPreloadCache.shared.cachedWKHLSURL(for: videoId) == nil {
                        await YouTubeWebViewHLSExtractor.preWarm(videoId: videoId)
                    }
                    let hasCachedURL = await VideoPreloadCache.shared.cachedWKHLSURL(for: videoId) != nil
                    let hasCachedPot = await VideoPreloadCache.shared.cachedPoToken(for: videoId) != nil
                    if hasCachedURL && !hasCachedPot && !YouTubeWebViewHLSExtractor.isPreWarming {
                        YouTubeWebViewHLSExtractor.isPreWarming = true
                        if let freshURL = await YouTubeWebViewHLSExtractor.shared.serialExtract(videoId: videoId) {
                            let freshPot = YouTubeWebViewHLSExtractor.shared.extractedPoToken
                            await VideoPreloadCache.shared.store(wkHLSManifestURL: freshURL, for: videoId, isPreWarm: true)
                            if let pot = freshPot {
                                await VideoPreloadCache.shared.store(wkHLSPoToken: pot, for: videoId)
                            }
                        }
                        YouTubeWebViewHLSExtractor.isPreWarming = false
                    }
                    CFNotificationCenterPostNotification(
                        CFNotificationCenterGetDarwinNotifyCenter(),
                        CFNotificationName("com.void.ipockettube.player.prewarm.done.\(videoId)" as CFString),
                        nil, nil, true
                    )
                    do {
                        try await Task.sleep(nanoseconds: 30_000_000_000)
                    } catch {
                        break outer
                    }
                    let stillCached = await VideoPreloadCache.shared.cachedWKHLSURL(for: videoId) != nil
                    if stillCached { break outer }
                }
            }
            #endif
            #endif
        }
        .contextMenu {
            #if !os(tvOS)
            if let shareURL = URL(string: "https://www.youtube.com/watch?v=\(video.id)") {
                ShareLink(item: shareURL) {
                    Label("Share", systemImage: AppSymbol.share)
                }
            }
            #endif
            if let channelId = video.channelId, !channelId.isEmpty {
                Button {
                    iPocketTubeHaptics.shared.perform(.channelSelection)
                    NotificationCenter.default.post(
                        name: .openChannel,
                        object: nil,
                        userInfo: ["channelId": channelId, "channelTitle": video.channelTitle]
                    )
                } label: {
                    Label("Open Channel", systemImage: AppSymbol.personRectangle)
                }
            }
            if authService.isSignedIn {
                if currentPlaylistId == "WL" {
                    Button(role: .destructive) {
                        iPocketTubeHaptics.shared.perform(.downloadDelete)
                        Task {
                            do {
                                try await api.removeFromWatchLater(videoId: video.id)
                                watchLaterAlert = DownloadAlertItem(
                                    title: String(localized: "Removed from Watch Later", bundle: .module),
                                    message: String(localized: "\"\(video.title)\" was removed from your Watch Later playlist.", bundle: .module)
                                )
                            } catch {
                                watchLaterAlert = DownloadAlertItem(
                                    title: String(localized: "Could Not Remove", bundle: .module),
                                    message: error.localizedDescription
                                )
                            }
                        }
                    } label: {
                        Label("Remove from Watch Later", systemImage: AppSymbol.watchLater)
                    }
                } else {
                    Button {
                        iPocketTubeHaptics.shared.perform(.primaryAction)
                        Task {
                            do {
                                try await api.addToWatchLater(videoId: video.id)
                                watchLaterAlert = DownloadAlertItem(
                                    title: String(localized: "Saved to Watch Later", bundle: .module),
                                    message: String(localized: "\"\(video.title)\" was added to your Watch Later playlist.", bundle: .module)
                                )
                            } catch {
                                watchLaterAlert = DownloadAlertItem(
                                    title: String(localized: "Could Not Save", bundle: .module),
                                    message: error.localizedDescription
                                )
                            }
                        }
                    } label: {
                        Label("Save to Watch Later", systemImage: AppSymbol.watchLater)
                    }
                }
            }
            Button {
                iPocketTubeHaptics.shared.perform(.primaryAction)
                Task { await CurrentQueueStore.shared.append(video) }
            } label: {
                Label("Add to Queue", systemImage: "text.badge.plus")
            }
            Button {
                iPocketTubeHaptics.shared.perform(.primaryAction)
                Task {
                    let count = await CurrentQueueStore.shared.videos.count
                    await CurrentQueueStore.shared.insertNext(video, afterIndex: count - 1)
                }
            } label: {
                Label("Play Next", systemImage: "text.insert")
            }
            if authService.isSignedIn {
                Button(role: .destructive) {
                    iPocketTubeHaptics.shared.perform(.downloadDelete)
                    Task {
                        if let token = video.notInterestedToken {
                            try? await api.sendFeedback(token: token)
                        } else {
                            try? await api.sendFeedbackForVideo(videoId: video.id, iconType: "NOT_INTERESTED")
                        }
                        NotificationCenter.default.post(
                            name: .hideVideoFromFeed,
                            object: nil,
                            userInfo: ["videoId": video.id]
                        )
                    }
                } label: {
                    Label("Not Interested", systemImage: "hand.raised")
                }
                if let channelId = video.channelId, !channelId.isEmpty {
                    Button(role: .destructive) {
                        iPocketTubeHaptics.shared.perform(.downloadDelete)
                        Task {
                            if let token = video.hideChannelToken {
                                try? await api.sendFeedback(token: token)
                            } else {
                                try? await api.sendFeedbackForVideo(videoId: video.id, iconType: "BLOCK_CHANNEL")
                            }
                            store.settings.blockedChannels[channelId] = video.channelTitle
                            NotificationCenter.default.post(
                                name: .hideChannelFromFeed,
                                object: nil,
                                userInfo: ["channelId": channelId]
                            )
                        }
                    } label: {
                        Label("Don't Recommend Channel", systemImage: "person.slash")
                    }
                }
            }
            #if !os(tvOS)
            Button {
                iPocketTubeHaptics.shared.perform(.primaryAction)
                downloadService.download(
                    video: video,
                    kind: .video,
                    saveVideoToPhotos: false,
                    storageLimitMB: store.settings.offlineStorageLimitMB
                )
            } label: {
                Label(
                    downloadService.state.isActive
                        ? String(localized: "Downloading…", bundle: .module)
                        : String(localized: "Save Video", bundle: .module),
                    systemImage: AppSymbol.download
                )
            }
            .disabled(downloadService.state.isActive)
            #endif
        } preview: {
            selectedLayout
            .padding(12)
            .frame(width: 300)
            .background(.background)
        }
        #if !os(tvOS)
        // Download state is observed at app-root level (RootView) so the alert
        // survives context menu dismiss animations that would otherwise reset
        // the card-level @State. Only the button label/disabled state is read here.
        .padding(0)  // zero-effect modifier to keep the view chain well-typed
        #endif
    }

    // MARK: - Body

    public var body: some View {
        #if os(tvOS)
        // Modifier order is critical on tvOS:
        //
        //   cardContent  (contains .contextMenu — handles long press)
        //       .focusable()          — registers view with focus engine (D-pad navigation)
        //       .onTapGesture { }     — fires on Select press (outermost → receives event first)
        //       .focused($isFocused)  — tracks focus state (does not consume events)
        //
        // Why this order works:
        // • .onTapGesture outermost → Select button press fires the action.
        //   (.focusable() outermost broke Select because the focus engine intercepted
        //    the primary-action event before the inner tap gesture could see it.)
        // • .contextMenu innermost, co-located in the same modifier chain as
        //   .onTapGesture → SwiftUI's gesture arbiter can cancel the pending tap
        //   recogniser when it detects a long press, so long press shows the menu
        //   without also playing the video.
        // • .focusable() between contextMenu and onTapGesture keeps the view in the
        //   focus engine so D-pad UP/DOWN can reach it.
        cardContent
            .iPocketTubeCardSurface(cornerRadius: 12)
            .focusable()
            .onTapGesture {
                iPocketTubeHaptics.shared.perform(.contentSelection)
                onSelect?()
            }
            .focused($isFocused)
            .onAppear { feedLog.info("[feed] id=\(self.video.id) title=\(self.video.title)") }
            .onChange(of: isFocused) { _, newValue in
                focusLog.info("[VideoCard] isFocused=\(newValue) id=\(self.video.id)")
                #if canImport(WebKit)
                if newValue, !video.isShort {
                    let videoId = video.id
                    Task(priority: .background) {
                        await YouTubeWebViewHLSExtractor.preWarm(videoId: videoId)
                    }
                }
                #endif
            }
            .shadow(color: isFocused ? .white.opacity(0.9) : .clear, radius: 18, x: 0, y: 0)
            .scaleEffect(isFocused ? 1.08 : 1.0)
            .zIndex(isFocused ? 1 : 0)
            .animation(.easeInOut(duration: 0.15), value: isFocused)
            .alert(item: $watchLaterAlert) { item in
                Alert(title: Text(item.title), message: Text(item.message), dismissButton: .default(Text("OK")))
            }
        #elseif os(iOS)
        cardContent
            .padding(.vertical, store.settings.themeName.usesTimelineLayout ? 2 : 5)
            .background {
                if store.settings.themeName.usesColorWash {
                    colorWashBackdrop
                } else if store.settings.themeName.usesSpatialDeckLayout ||
                            store.settings.themeName.usesSignalMapLayout ||
                            store.settings.themeName.usesPrismLayout {
                    creativeCardBackdrop
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(Rectangle())
            .onAppear { feedLog.info("[feed] id=\(self.video.id) title=\(self.video.title)") }
            .alert(item: $watchLaterAlert) { item in
                Alert(title: Text(item.title), message: Text(item.message), dismissButton: .default(Text("OK")))
            }
        #else
        cardContent
            .padding(.vertical, 5)
            .onAppear { feedLog.info("[feed] id=\(self.video.id) title=\(self.video.title)") }
            .alert(item: $watchLaterAlert) { item in
                Alert(title: Text(item.title), message: Text(item.message), dismissButton: .default(Text("OK")))
            }
        #endif
    }

    @ViewBuilder
    private var selectedLayout: some View {
        if store.settings.themeName.usesTimelineLayout {
            timelineLayout
        } else if store.settings.themeName.usesPosterLayout {
            posterLayout
        } else if store.settings.themeName.usesSpatialDeckLayout {
            spatialDeckLayout
        } else if store.settings.themeName.usesSignalMapLayout {
            signalMapLayout
        } else if store.settings.themeName.usesPrismLayout {
            prismLayout
        } else if compact {
            compactLayout
        } else {
            gridLayout
        }
    }

    // MARK: Grid layout (default)

    private var gridLayout: some View {
        VStack(alignment: .leading, spacing: 6) {
            Color.clear
                .aspectRatio(16 / 9, contentMode: .fit)
                .overlay(thumbnailView.clipped())
                .overlay(alignment: .bottom) {
                    if let progress = effectiveProgress, progress > 0 {
                        watchProgressBar(progress)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .bottomTrailing) {
                    let dur = video.formattedDuration
                    if !dur.isEmpty { durationBadge(dur) }
                }
                .overlay(alignment: .topLeading) {
                    if video.isLive { liveBadge }
                }

            VStack(alignment: .leading, spacing: 2) {
                Text(displayTitle)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(3)
                    .accessibilityIdentifier("video.card.title")
                Text(video.channelTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .onTapGesture {
                        guard let channelId = video.channelId, !channelId.isEmpty else { return }
                        iPocketTubeHaptics.shared.perform(.channelSelection)
                        NotificationCenter.default.post(
                            name: .openChannel,
                            object: nil,
                            userInfo: ["channelId": channelId, "channelTitle": video.channelTitle]
                        )
                    }
                    .accessibilityIdentifier("video.card.channelName")
                HStack(spacing: 4) {
                    let vc = video.formattedViewCount
                    if !vc.isEmpty { Text(vc) }
                }
                .font(.caption2)
                .foregroundStyle(iPocketTubeVisualTokens.secondaryText)
                if VideoPublicationPresentationPolicy.showsPublicationDate(for: video) {
                    VideoPublicationLabel(video: video)
                }
            }
            .padding(.horizontal, 2)
        }
    }

    // MARK: Compact (list) layout

    private var compactLayout: some View {
        HStack(alignment: .center, spacing: 12) {
            thumbnailView
                .frame(width: 144, height: 81)
                .overlay(alignment: .bottom) {
                    if let progress = effectiveProgress, progress > 0 {
                        watchProgressBar(progress)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(alignment: .bottomTrailing) {
                    let dur = video.formattedDuration
                    if !dur.isEmpty { durationBadge(dur) }
                }
            VStack(alignment: .leading, spacing: 3) {
                Text(displayTitle)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                    .accessibilityIdentifier("video.card.title")
                HStack(spacing: 4) {
                    Text(video.channelTitle)
                        .lineLimit(1)
                    let vc = video.formattedViewCount
                    if !vc.isEmpty {
                        Text("•")
                        Text(vc).lineLimit(1)
                    }
                }
                    .font(.caption)
                    .foregroundStyle(iPocketTubeVisualTokens.secondaryText)
                    .onTapGesture {
                        guard let channelId = video.channelId, !channelId.isEmpty else { return }
                        iPocketTubeHaptics.shared.perform(.channelSelection)
                        NotificationCenter.default.post(
                            name: .openChannel,
                            object: nil,
                            userInfo: ["channelId": channelId, "channelTitle": video.channelTitle]
                        )
                    }
                    .accessibilityIdentifier("video.card.channelName")
                if VideoPublicationPresentationPolicy.showsPublicationDate(for: video) {
                    VideoPublicationLabel(video: video)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var timelineLayout: some View {
        HStack(alignment: .center, spacing: 10) {
            timelineRail

            thumbnailView
                .frame(width: 126, height: 71)
                .overlay(alignment: .bottom) {
                    if let progress = effectiveProgress, progress > 0 {
                        watchProgressBar(progress)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(alignment: .bottomTrailing) {
                    let duration = video.formattedDuration
                    if !duration.isEmpty { durationBadge(duration) }
                }

            VStack(alignment: .leading, spacing: 3) {
                Text(displayTitle)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(3)
                    .accessibilityIdentifier("video.card.title")

                HStack(spacing: 4) {
                    Text(video.channelTitle).lineLimit(1)
                    let viewCount = video.formattedViewCount
                    if !viewCount.isEmpty {
                        Text("•")
                        Text(viewCount).lineLimit(1)
                    }
                }
                .font(.caption)
                .foregroundStyle(iPocketTubeVisualTokens.secondaryText)
                .accessibilityIdentifier("video.card.channelName")

                if VideoPublicationPresentationPolicy.showsPublicationDate(for: video) {
                    VideoPublicationLabel(video: video)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var posterLayout: some View {
        Color.clear
            .aspectRatio(compact ? 16 / 7 : 16 / 9, contentMode: .fit)
            .overlay {
                thumbnailView
                    .overlay {
                        LinearGradient(
                            colors: [.clear, .black.opacity(0.18), .black.opacity(0.92)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    }
            }
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(displayTitle)
                        .font(compact ? .headline : .title3.bold())
                        .foregroundStyle(.white)
                        .lineLimit(compact ? 2 : 3)
                        .shadow(color: .black.opacity(0.6), radius: 5, y: 2)
                        .accessibilityIdentifier("video.card.title")

                    HStack(spacing: 5) {
                        Text(video.channelTitle).lineLimit(1)
                        let viewCount = video.formattedViewCount
                        if !viewCount.isEmpty {
                            Text("·")
                            Text(viewCount).lineLimit(1)
                        }
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white.opacity(0.78))

                    if VideoPublicationPresentationPolicy.showsPublicationDate(for: video) {
                        VideoPublicationLabel(video: video)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color.orange.opacity(0.95))
                    }
                }
                .padding(14)
            }
            .overlay(alignment: .bottom) {
                if let progress = effectiveProgress, progress > 0 {
                    watchProgressBar(progress)
                }
            }
            .overlay(alignment: .topTrailing) {
                let duration = video.formattedDuration
                if !duration.isEmpty { durationBadge(duration) }
            }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(color: Color.red.opacity(0.13), radius: 18, y: 8)
    }

    private var spatialDeckLayout: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.purple.opacity(0.25))
                    .frame(width: 146, height: 86)
                    .offset(x: 7, y: 7)
                thumbnailView
                    .frame(width: 146, height: 86)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(alignment: .bottom) {
                        if let progress = effectiveProgress, progress > 0 {
                            watchProgressBar(progress)
                        }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        let duration = video.formattedDuration
                        if !duration.isEmpty { durationBadge(duration) }
                    }
            }
            .padding(.trailing, 7)
            .padding(.bottom, 7)

            creativeMetadata(accent: .cyan)
            Spacer(minLength: 0)
        }
        .padding(12)
    }

    private var signalMapLayout: some View {
        HStack(alignment: .center, spacing: 11) {
            Capsule()
                .fill(creativeAccent)
                .frame(width: 5, height: 72)

            thumbnailView
                .frame(width: 116, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .overlay(alignment: .bottom) {
                    if let progress = effectiveProgress, progress > 0 {
                        watchProgressBar(progress)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    let duration = video.formattedDuration
                    if !duration.isEmpty { durationBadge(duration) }
                }

            creativeMetadata(accent: creativeAccent)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
    }

    private var prismLayout: some View {
        HStack(alignment: .center, spacing: 13) {
            thumbnailView
                .frame(width: 138, height: 84)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(alignment: .bottom) {
                    if let progress = effectiveProgress, progress > 0 {
                        watchProgressBar(progress)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    let duration = video.formattedDuration
                    if !duration.isEmpty { durationBadge(duration) }
                }

            creativeMetadata(accent: Color(red: 0.62, green: 0.90, blue: 1.0))
            Spacer(minLength: 0)
        }
        .padding(12)
    }

    private func creativeMetadata(accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(displayTitle)
                .font(.subheadline.weight(.bold))
                .lineLimit(3)
                .accessibilityIdentifier("video.card.title")
            HStack(spacing: 4) {
                Text(video.channelTitle).lineLimit(1)
                let viewCount = video.formattedViewCount
                if !viewCount.isEmpty {
                    Text("·")
                    Text(viewCount).lineLimit(1)
                }
            }
            .font(.caption)
            .foregroundStyle(iPocketTubeVisualTokens.secondaryText)
            .accessibilityIdentifier("video.card.channelName")
            if VideoPublicationPresentationPolicy.showsPublicationDate(for: video) {
                VideoPublicationLabel(video: video)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(accent)
                    .lineLimit(1)
            }
        }
    }

    private var timelineRail: some View {
        VStack(alignment: .trailing, spacing: 3) {
            Text(timelineDayLabel)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(iPocketTubeVisualTokens.mintSoft)
            Text(timelineTimeLabel)
                .font(.caption2)
                .foregroundStyle(iPocketTubeVisualTokens.secondaryText)
        }
        .multilineTextAlignment(.trailing)
        .lineLimit(2)
        .frame(width: 54, alignment: .trailing)
        .padding(.trailing, 10)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(iPocketTubeVisualTokens.mint.opacity(0.22))
                .frame(width: 1)
                .overlay {
                    Circle()
                        .fill(iPocketTubeVisualTokens.mint)
                        .frame(width: 7, height: 7)
                }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Опубликовано: \(timelineDayLabel), \(timelineTimeLabel)")
    }

    private var timelineDayLabel: String {
        guard let publishedAt = video.publishedAt else { return "Видео" }
        if Calendar.autoupdatingCurrent.isDateInToday(publishedAt) { return "Сегодня" }
        if Calendar.autoupdatingCurrent.isDateInYesterday(publishedAt) { return "Вчера" }
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.setLocalizedDateFormatFromTemplate("d MMM")
        return formatter.string(from: publishedAt)
    }

    private var timelineTimeLabel: String {
        guard let publishedAt = video.publishedAt else {
            return VideoPublicationFormatter.string(for: video)
        }
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: publishedAt)
    }

    // MARK: Shared

    /// Returns the DeArrow thumbnail URL if the feature is enabled and a timestamp is available.
    private var deArrowThumbnailURL: URL? {
        guard store.settings.deArrowEnabled,
              let ts = video.deArrowThumbnailTimestamp else { return nil }
        return URL(string: "https://i.ytimg.com/vi/\(video.id)/\(Int(ts)).jpg")
    }

    private var ambientThumbnailURL: URL? {
        deArrowThumbnailURL ?? video.thumbnailURL ?? video.thumbnailFallbackURLs.first
    }

    /// The title to show — community de-arrow title when enabled, raw title otherwise.
    private var displayTitle: String {
        if store.settings.deArrowEnabled, let t = video.deArrowTitle { return t }
        return video.title
    }

    @ViewBuilder
    private var thumbnailView: some View {
        if video.thumbnailURL == nil, video.id == "WL" || video.id == "LL" {
            systemPlaylistThumbnail
        } else {
            // Walk a fallback chain on each successive failure:
            //   -1 → deArrowThumbnailURL (community thumbnail) or thumbnailURL (API-provided)
            //    0 → sddefault.jpg  (640×480, available for most videos)
            //    1 → hqdefault.jpg  (480×360, always available)
            //    2 → mqdefault.jpg  (320×180, always available — last resort)
            let fallbacks = video.thumbnailFallbackURLs
            let url: URL? = thumbnailFallbackIndex < 0
                ? (deArrowThumbnailURL ?? video.thumbnailURL ?? fallbacks.first)
                : (thumbnailFallbackIndex < fallbacks.count ? fallbacks[thumbnailFallbackIndex] : nil)
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let img):
                    themedThumbnail(img)
                case .failure:
                    let nextIndex = thumbnailFallbackIndex + 1
                    if nextIndex < fallbacks.count {
                        placeholderThumbnail
                            .onAppear { thumbnailFallbackIndex = nextIndex }
                    } else {
                        placeholderThumbnail
                    }
                default:
                    placeholderThumbnail.overlay(ProgressView())
                }
            }
            .task(id: video.id) {
                // Reset so a reused card slot always tries the primary URL for the new video.
                thumbnailFallbackIndex = -1
                #if canImport(WebKit)
                await BotGuardWebViewRunner.shared.prepare()
                #if !os(iOS)
                if !video.isShort {
                    let videoId = video.id
                    while !Task.isCancelled {
                        await YouTubeWebViewHLSExtractor.preWarm(videoId: videoId)
                        if await VideoPreloadCache.shared.cachedWKHLSURL(for: videoId) != nil { break }
                        try? await Task.sleep(nanoseconds: 4_000_000_000)
                    }
                }
                #endif
                #endif
            }
        }
    }

    @ViewBuilder
    private func themedThumbnail(_ image: Image) -> some View {
        if store.settings.themeName.usesMonochromeThumbnails {
            image
                .resizable()
                .scaledToFill()
                .saturation(0)
                .contrast(1.06)
                .colorMultiply(
                    store.settings.themeName == .matrix
                        ? Color(red: 0.76, green: 1.00, blue: 0.82)
                        : Color(red: 0.88, green: 1.00, blue: 0.91)
                )
        } else {
            image
                .resizable()
                .scaledToFill()
        }
    }

    private var colorWashBackdrop: some View {
        GeometryReader { geometry in
            AsyncImage(url: ambientThumbnailURL) { phase in
                if case .success(let image) = phase {
                    image
                        .resizable()
                        .scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .saturation(1.15)
                        .blur(radius: 30)
                        .opacity(store.settings.themeName == .colorWashDark ? 0.22 : 0.15)
                        .overlay(
                            iPocketTubeVisualTokens.background.opacity(
                                store.settings.themeName == .colorWashDark ? 0.42 : 0.28
                            )
                        )
                } else {
                    iPocketTubeVisualTokens.panel.opacity(0.08)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var creativeCardBackdrop: some View {
        switch store.settings.themeName {
        case .spatialDeck:
            LinearGradient(
                colors: [Color.cyan.opacity(0.12), Color.purple.opacity(0.15)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .background(.thinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(color: Color.cyan.opacity(0.12), radius: 16, y: 7)

        case .signalMap:
            Color.white.opacity(0.82)
                .background(.thinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .shadow(color: Color.blue.opacity(0.09), radius: 12, y: 5)

        case .prismRooms:
            LinearGradient(
                colors: [
                    Color.purple.opacity(0.34),
                    Color.blue.opacity(0.18),
                    Color.cyan.opacity(0.16)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .shadow(color: Color.purple.opacity(0.18), radius: 18, y: 8)

        default:
            EmptyView()
        }
    }

    private var creativeAccent: Color {
        let palette: [Color] = [
            Color(red: 0.05, green: 0.40, blue: 0.95),
            Color(red: 0.96, green: 0.38, blue: 0.12),
            Color(red: 0.54, green: 0.20, blue: 0.92),
            Color(red: 0.02, green: 0.58, blue: 0.47)
        ]
        let scalar = video.id.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return palette[scalar % palette.count]
    }

    private var systemPlaylistThumbnail: some View {
        let icon = video.id == "WL" ? "clock.fill" : "hand.thumbsup.fill"
        return ZStack {
            Rectangle().fill(Color.secondary.opacity(0.15))
            Image(systemName: icon)
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(Color.secondary)
        }
    }

    private var placeholderThumbnail: some View {
        Rectangle().fill(Color.secondary.opacity(0.2))
    }

    private func watchProgressBar(_ fraction: Double) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(Color.black.opacity(0.3))
                Rectangle()
                    .fill(iPocketTubeVisualTokens.mint)
                    .frame(width: geo.size.width * fraction)
            }
        }
        .frame(height: 3)
    }

    private func durationBadge(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .fontWeight(.semibold)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(.black.opacity(0.75))
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .padding(4)
    }

    private var liveBadge: some View {
        Text("LIVE")
            .font(.caption2)
            .fontWeight(.bold)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(.red)
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .padding(4)
    }
}

// MARK: - Preview

#if DEBUG
#Preview {
    VideoCardView(video: Video(
        id: "dQw4w9WgXcQ",
        title: "Rick Astley – Never Gonna Give You Up",
        channelTitle: "Rick Astley",
        duration: 213,
        viewCount: 1_400_000_000
    ))
    .frame(width: 320)
    .padding()
}
#endif
