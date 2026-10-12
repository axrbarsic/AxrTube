#if os(iOS)
import SwiftUI
import iPocketTubeCore

/// The "You" tab: account header plus history, playlists, downloads and settings.
struct YTYouView: View {
    enum Destination: Hashable {
        case history, playlists, watchLater, liked, downloads, settings
    }

    @Environment(AuthService.self) private var auth
    @Environment(DownloadStore.self) private var downloadStore
    @Environment(\.innerTubeAPI) private var api
    @State private var showSignIn = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                accountHeader
                    .padding(.horizontal, 16)
                    .padding(.vertical, 16)
                Divider().overlay(YTColor.divider)
                if auth.isSignedIn {
                    row(.history, "История", "clock.arrow.circlepath")
                    row(.playlists, "Плейлисты", "list.bullet.rectangle")
                    row(.watchLater, "Смотреть позже", "clock")
                    row(.liked, "Понравившиеся видео", "hand.thumbsup")
                    Divider().overlay(YTColor.divider).padding(.vertical, 6)
                }
                row(.downloads, "Загрузки", "arrow.down.circle", detail: downloadsDetail)
                row(.settings, "Настройки", "gearshape")
            }
        }
        .background(YTColor.background)
        .navigationDestination(for: Destination.self) { destination in
            switch destination {
            case .history:
                YTFeedView(type: .history, requiresSignIn: true, api: api).navigationTitle("История")
            case .playlists:
                YTFeedView(type: .playlists, requiresSignIn: true, api: api).navigationTitle("Плейлисты")
            case .watchLater:
                PlaylistView(playlistId: "WL", playlistTitle: "Смотреть позже", api: api, catalogContext: .mediaLibrary)
            case .liked:
                PlaylistView(playlistId: "LL", playlistTitle: "Понравившиеся видео", api: api, catalogContext: .mediaLibrary)
            case .downloads:
                DownloadsView()
            case .settings:
                SettingsView()
            }
        }
        .sheet(isPresented: $showSignIn) { SignInView() }
    }

    @ViewBuilder private var accountHeader: some View {
        if auth.isSignedIn {
            HStack(spacing: 14) {
                AsyncImage(url: auth.accountAvatarURL) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFill()
                    } else {
                        YTChannelAvatar(title: auth.accountName ?? "?", size: 64)
                    }
                }
                .frame(width: 64, height: 64)
                .clipShape(Circle())
                Text(auth.accountName ?? "Аккаунт")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(YTColor.primaryText)
            }
        } else {
            HStack(spacing: 14) {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(YTColor.secondaryText)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Вы не вошли в аккаунт")
                        .font(.headline)
                        .foregroundStyle(YTColor.primaryText)
                    Button("Войти") { showSignIn = true }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color(hex: 0x3EA6FF))
                }
            }
        }
    }

    private var downloadsDetail: String? {
        let count = downloadStore.entries.filter { $0.status == .completed }.count
        return count > 0 ? "\(count)" : nil
    }

    private func row(_ destination: Destination, _ title: String, _ icon: String, detail: String? = nil) -> some View {
        NavigationLink(value: destination) {
            HStack(spacing: 22) {
                Image(systemName: icon)
                    .font(.system(size: 20))
                    .frame(width: 26)
                Text(title).font(.system(size: 16))
                Spacer()
                if let detail {
                    Text(detail).font(.system(size: 14)).foregroundStyle(YTColor.secondaryText)
                }
            }
            .foregroundStyle(YTColor.primaryText)
            .padding(.horizontal, 16)
            .frame(height: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(YTPressStyle())
        .accessibilityIdentifier("you.\(destination)")
    }
}
#endif
