#if os(iOS)
import SwiftUI
import iPocketTubeCore

/// YouTube comments panel: server sort chips, endless list, expandable replies.
struct YTCommentsSheet: View {
    let videoID: String
    var onClose: (() -> Void)? = nil

    @Environment(\.innerTubeAPI) private var api
    @Environment(\.dismiss) private var dismiss
    @State private var page = CommentsPage.empty
    @State private var sort: CommentSortOption?
    @State private var isLoading = true
    @State private var isLoadingMore = false
    @State private var failed = false
    @State private var replies: [String: [iPocketTubeCore.Comment]] = [:]
    @State private var loadingReplies: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(YTColor.divider)
            content
        }
        .background(YTColor.background)
        .task(id: videoID) { await loadFirst() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Комментарии").font(.system(size: 18, weight: .bold))
                Spacer()
                Button { if let onClose { onClose() } else { dismiss() } } label: {
                    Image(systemName: "xmark").font(.system(size: 17, weight: .medium)).frame(width: 40, height: 40)
                }
                .accessibilityLabel("Закрыть")
            }
            if page.sortOptions.count > 1 {
                HStack(spacing: 8) {
                    ForEach(page.sortOptions) { option in
                        let selected = option == (sort ?? page.sortOptions.first)
                        Button { Task { await select(option) } } label: {
                            Text(option.title)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(selected ? YTColor.chipSelectedText : YTColor.primaryText)
                                .padding(.horizontal, 12)
                                .frame(height: 32)
                                .background(selected ? YTColor.chipSelected : YTColor.chip, in: RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .foregroundStyle(YTColor.primaryText)
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    @ViewBuilder private var content: some View {
        if isLoading && page.comments.isEmpty {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if page.comments.isEmpty {
            VStack(spacing: 12) {
                Text(failed ? "Не удалось загрузить комментарии" : "Комментариев пока нет")
                    .foregroundStyle(YTColor.secondaryText)
                if failed { Button("Повторить") { Task { await loadFirst() } } }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(page.comments) { comment in
                        VStack(alignment: .leading, spacing: 10) {
                            CommentRowView(comment: comment)
                            repliesBlock(for: comment)
                        }
                        .onAppear { if comment.id == page.comments.last?.id { Task { await loadMore() } } }
                    }
                    if isLoadingMore { ProgressView().frame(maxWidth: .infinity) }
                }
                .padding(16)
            }
        }
    }

    @ViewBuilder private func repliesBlock(for comment: iPocketTubeCore.Comment) -> some View {
        if let loaded = replies[comment.id] {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(loaded) { CommentRowView(comment: $0) }
            }
            .padding(.leading, 46)
        } else if let token = page.replyTokens[comment.id] {
            Button {
                Task { await loadReplies(comment.id, token: token) }
            } label: {
                HStack(spacing: 6) {
                    if loadingReplies.contains(comment.id) { ProgressView().controlSize(.small) }
                    Text(page.replyLabels[comment.id] ?? "Ответы")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color(hex: 0x3EA6FF))
                }
            }
            .buttonStyle(.plain)
            .padding(.leading, 46)
        }
    }

    // MARK: Loading

    private func loadFirst() async {
        isLoading = true
        failed = false
        do {
            page = try await api.fetchCommentsPage(videoId: videoID)
        } catch {
            failed = true
        }
        isLoading = false
    }

    private func select(_ option: CommentSortOption) async {
        guard option != (sort ?? page.sortOptions.first) else { return }
        sort = option
        let options = page.sortOptions
        isLoading = true
        replies = [:]
        do {
            var next = try await api.fetchCommentsPage(continuation: option.token)
            if next.sortOptions.isEmpty { next.sortOptions = options }
            page = next
        } catch {
            failed = true
        }
        isLoading = false
    }

    private func loadMore() async {
        guard let token = page.nextToken, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        guard let next = try? await api.fetchCommentsPage(continuation: token) else { return }
        let known = Set(page.comments.map(\.id))
        page.comments += next.comments.filter { !known.contains($0.id) }
        page.replyTokens.merge(next.replyTokens) { old, _ in old }
        page.replyLabels.merge(next.replyLabels) { old, _ in old }
        page.nextToken = next.nextToken == token ? nil : next.nextToken
    }

    private func loadReplies(_ id: String, token: String) async {
        guard !loadingReplies.contains(id) else { return }
        loadingReplies.insert(id)
        defer { loadingReplies.remove(id) }
        var collected: [iPocketTubeCore.Comment] = []
        var cursor: String? = token
        // Replies arrive ten at a time; follow "Показать другие ответы" up to a bound.
        for _ in 0..<5 {
            guard let current = cursor, let next = try? await api.fetchCommentsPage(continuation: current) else { break }
            collected += next.comments
            cursor = next.nextToken == current ? nil : next.nextToken
            if cursor == nil { break }
        }
        replies[id] = collected
    }
}
#endif
