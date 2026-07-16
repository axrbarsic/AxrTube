import Foundation
import iPocketTubeCore

extension AuthService {

    // MARK: - User info

    func fetchUserInfo() async throws {
        authLog.notice("fetchUserInfo() — calling validAccessToken()")
        let token = try await validAccessToken()
        authLog.notice("fetchUserInfo() — token len=\(token.count), calling InnerTube accounts_list API")
        // Android methodology: POST to www.youtube.com/youtubei/v1/account/accounts_list
        // with TV client context + accountReadMask. Mirrors AuthApi.java @POST accounts_list
        // and AuthApiHelper.getAccountsListQuery() which uses PostDataHelper.createQueryTV().
        var req = URLRequest(url: Self.accountsListURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let body: [String: Any] = [
            "context": [
                "client": [
                    "hl": "en",
                    "gl": "US",
                    "clientName": InnerTubeClients.TV.name,
                    "clientVersion": InnerTubeClients.TV.version,
                ]
            ],
            "accountReadMask": [
                "returnOwner": true,
                "returnBrandAccounts": true,
                "returnPersonaAccounts": false
            ]
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: req)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        authLog.notice("fetchUserInfo() — HTTP \(statusCode)")
        if let bodyStr = String(data: data, encoding: .utf8) {
            authLog.notice("fetchUserInfo() — response: \(String(bodyStr.prefix(600)))")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            authLog.error("fetchUserInfo() — JSON parse failed")
            return
        }
        let accountItem = extractAccountItem(from: json)
        guard let item = accountItem else {
            authLog.error("fetchUserInfo() — could not find accountItem; top-level keys=\(Array(json.keys))")
            return
        }
        if let nameDict = item["accountName"] as? [String: Any] {
            accountName = (nameDict["runs"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined()
                ?? nameDict["simpleText"] as? String
        }
        authLog.notice("fetchUserInfo() — accountName=\(self.accountName ?? "nil")")
        if let photoDict = item["accountPhoto"] as? [String: Any],
           let thumbnails = photoDict["thumbnails"] as? [[String: Any]],
           let last = thumbnails.last,
           let urlStr = last["url"] as? String {
            accountAvatarURL = URL(string: urlStr.hasPrefix("//") ? "https:\(urlStr)" : urlStr)
            authLog.notice("fetchUserInfo() — avatarURL=\(urlStr)")
        }
        saveToKeychain()
    }

    /// Walk Android's AccountsList JSON path:
    /// contents[0].accountSectionListRenderer.contents[0].accountItemSectionRenderer.contents[].accountItem
    /// Returns the first account with isSelected==true, or the first available account.
    func extractAccountItem(from json: [String: Any]) -> [String: Any]? {
        guard let contents = json["contents"] as? [[String: Any]],
              let firstSection = contents.first,
              let sectionListRenderer = firstSection["accountSectionListRenderer"] as? [String: Any],
              let sectionContents = sectionListRenderer["contents"] as? [[String: Any]],
              let firstItemSection = sectionContents.first,
              let itemSectionRenderer = firstItemSection["accountItemSectionRenderer"] as? [String: Any],
              let items = itemSectionRenderer["contents"] as? [[String: Any]]
        else { return nil }
        return items.compactMap { $0["accountItem"] as? [String: Any] }
            .first(where: { $0["isSelected"] as? Bool == true })
            ?? items.compactMap { $0["accountItem"] as? [String: Any] }.first
    }
}
