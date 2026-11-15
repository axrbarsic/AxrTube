#if os(iOS)
import SwiftUI
import iPocketTubeCore

// MARK: - YouTube description panel
//
// Slides over the details area under the player (portrait), like YouTube:
// title, likes / views / date, description with links and timestamps,
// chapters, transcript entry and the channel.
extension PlayerView {

    var ytDescriptionPanel: some View {
        let current = watchVideo
        let description = current.description ?? ""
        return VStack(spacing: 0) {
            HStack {
                Text("Описание").font(.system(size: 18, weight: .bold))
                Spacer()
                Button { showDescriptionSheet = false } label: {
                    Image(systemName: "xmark").font(.system(size: 17)).frame(width: 40, height: 40)
                }
                .accessibilityLabel("Закрыть")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            Divider().overlay(YTColor.divider)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(current.title).font(.system(size: 18, weight: .bold))
                    stats(for: current)
                    if !description.isEmpty {
                        Text(descriptionAttributedString(description))
                            .font(.system(size: 14))
                            .tint(Color(hex: 0x3EA6FF))
                            .textSelection(.enabled)
                    } else {
                        Text("Описания нет").foregroundStyle(YTColor.secondaryText)
                    }
                    if !vm.chapters.isEmpty { chapters }
                    transcriptEntry
                    channelEntry(for: current)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
        }
        .foregroundStyle(YTColor.primaryText)
        .background(YTColor.background)
        .accessibilityIdentifier("watch.description")
    }

    private func stats(for video: Video) -> some View {
        HStack(spacing: 0) {
            stat(ownerModel.info.likeCountText ?? "—", "Отметки «Нравится»")
            stat(video.viewCount.map { YouTubeMetaFormatter.views($0).replacingOccurrences(of: " просмотров", with: "") } ?? "—", "Просмотры")
            stat(VideoPublicationFormatter.string(for: video).isEmpty ? "—" : VideoPublicationFormatter.string(for: video), "Дата")
        }
    }

    private func stat(_ value: String, _ caption: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.system(size: 16, weight: .bold)).lineLimit(1).minimumScaleFactor(0.7)
            Text(caption).font(.system(size: 12)).foregroundStyle(YTColor.secondaryText).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }

    private var chapters: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Главы").font(.system(size: 16, weight: .bold))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(vm.chapters) { chapter in
                        Button {
                            iPocketTubeHaptics.shared.perform(.seekCommit)
                            vm.seek(to: chapter.startTime)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(chapter.title).font(.system(size: 13, weight: .medium)).lineLimit(2)
                                Text(formatDuration(chapter.startTime))
                                    .font(.system(size: 12))
                                    .foregroundStyle(Color(hex: 0x3EA6FF))
                            }
                            .padding(10)
                            .frame(width: 160, alignment: .leading)
                            .background(YTColor.chip, in: RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var transcriptEntry: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Текст видео").font(.system(size: 16, weight: .bold))
            Text("Полная стенограмма с переводом и копированием.")
                .font(.system(size: 13))
                .foregroundStyle(YTColor.secondaryText)
            Button {
                showDescriptionSheet = false
                showTranscript = true
            } label: {
                Text("Показать текст видео")
                    .font(.system(size: 14, weight: .semibold))
                    .padding(.horizontal, 14)
                    .frame(height: 36)
                    .overlay(Capsule().stroke(YTColor.divider))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("watch.description.transcript")
        }
    }

    private func channelEntry(for video: Video) -> some View {
        Button {
            guard let id = ownerModel.info.channelId ?? video.channelId, !id.isEmpty else { return }
            NotificationCenter.default.post(name: .openChannel, object: nil, userInfo: ["channelId": id])
            playerState.minimize()
        } label: {
            HStack(spacing: 12) {
                AsyncImage(url: ownerModel.info.avatarURL) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFill()
                    } else {
                        YTChannelAvatar(title: video.channelTitle, size: 44)
                    }
                }
                .frame(width: 44, height: 44)
                .clipShape(Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(ownerModel.info.channelTitle ?? video.channelTitle).font(.system(size: 15, weight: .semibold))
                    if let subs = ownerModel.info.subscriberText {
                        Text(subs).font(.system(size: 12)).foregroundStyle(YTColor.secondaryText)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(YTColor.secondaryText)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
#endif
