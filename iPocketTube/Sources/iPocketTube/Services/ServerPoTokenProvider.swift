import Foundation
import iPocketTubeCore

// MARK: - ServerPoTokenProvider
//
// Proof-of-Origin token provider that calls a user-configured self-hosted microservice.
// Intended as a developer/testing tool to validate poToken injection plumbing end-to-end
// before the full WKWebView-based BotGuard implementation is ready.
//
// Compatible servers:
//   - https://github.com/iv-org/youtube-trusted-session-generator
//   - Any endpoint that accepts POST {"videoId": "<id>"} and returns {"token": "<token>"}
//
// Configuration: set AppSettings.poTokenServiceURL to the server's base URL.
// This class is not wired up to InnerTubeAPI unless poTokenServiceURL is non-nil.

public struct ServerPoTokenProvider: PoTokenProvider {
    private let serviceURL: URL
    private let session: URLSession

    public init(serviceURL: URL, session: URLSession = .shared) {
        self.serviceURL = serviceURL
        self.session = session
    }

    public func token(for videoId: String) async throws -> String {
        let endpoint = serviceURL.appendingPathComponent("token")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["videoId": videoId])
        request.timeoutInterval = 10
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw APIError.httpError(code)
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["token"] as? String, !token.isEmpty else {
            throw APIError.decodingError("ServerPoTokenProvider: missing 'token' in response")
        }
        return token
    }
}
