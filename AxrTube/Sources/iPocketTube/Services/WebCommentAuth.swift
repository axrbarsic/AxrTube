#if os(iOS)
import Foundation
import Observation
import Security
import iPocketTubeCore

/// Web sign-in used for writing comments (the TV sign-in cannot). Keeps the
/// youtube.com cookies in the Keychain, feeds them to `YouTubeWebClient`
/// and remembers whether YouTube offers the comment box for this account.
@MainActor
@Observable
final class WebCommentAuth {
    static let shared = WebCommentAuth()

    enum Status: Equatable {
        case signedOut
        case checking
        case ready(account: String?)
        case limited(String)
    }

    private(set) var status: Status = .signedOut
    private var started = false

    var canComment: Bool {
        if case .ready = status { return true }
        return false
    }

    func start() {
        guard !started else { return }
        started = true
        let stored = Keychain.load()
        Task {
            await YouTubeWebClient.shared.configure(session: stored) { session in
                Keychain.save(session)
            }
            if stored?.isSignedIn == true { await verify() }
        }
    }

    func signedIn(with session: YouTubeWebSession) async {
        await YouTubeWebClient.shared.setSession(session)
        await verify()
    }

    func verify() async {
        status = .checking
        do {
            let result = try await YouTubeWebClient.shared.verify()
            if result.canComment {
                status = .ready(account: result.accountName)
            } else if result.signedIn {
                status = .limited("YouTube не разрешает этому аккаунту комментировать (нет канала или ограничение)")
            } else {
                status = .limited("YouTube не принял вход. Войдите ещё раз.")
            }
        } catch YouTubeWebClient.Failure.notSignedIn {
            status = .signedOut
        } catch {
            status = .limited("Не удалось проверить вход: \(error.localizedDescription)")
        }
    }

    func signOut() async {
        await YouTubeWebClient.shared.setSession(nil)
        status = .signedOut
    }

    /// Generic-password item, this device only, not in backups.
    enum Keychain {
        private static let service = "com.alexlane.axrtube.web-session"
        private static let account = "youtube"

        static func load() -> YouTubeWebSession? {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecReturnData as String: true,
            ]
            var item: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
            return try? JSONDecoder().decode(YouTubeWebSession.self, from: data)
        }

        static func save(_ session: YouTubeWebSession?) {
            let base: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
            ]
            SecItemDelete(base as CFDictionary)
            guard let session, let data = try? JSONEncoder().encode(session) else { return }
            var add = base
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(add as CFDictionary, nil)
        }
    }
}
#endif
