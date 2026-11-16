import CryptoKit
import Foundation

/// youtube.com web sign-in captured from the «Вход для комментариев» page.
/// The TV sign-in the app uses for feeds cannot write comments; this one
/// can, because requests carry the same cookies and SAPISID hashes as the
/// YouTube website. Stored only in the iPhone Keychain.
public struct YouTubeWebSession: Codable, Equatable, Sendable {
    /// Cookie name → value for youtube.com.
    public var cookies: [String: String]
    public var savedAt: Date

    public init(cookies: [String: String], savedAt: Date = Date()) {
        self.cookies = cookies
        self.savedAt = savedAt
    }

    /// Cookies that prove a signed-in web session.
    public static let requiredCookieNames = ["SAPISID", "__Secure-3PAPISID"]

    public var isSignedIn: Bool {
        Self.requiredCookieNames.contains { !(cookies[$0] ?? "").isEmpty }
    }

    public var cookieHeader: String {
        cookies.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
    }

    /// `Authorization` as the website sends it:
    /// `SAPISIDHASH ts_h SAPISID1PHASH ts_h1 SAPISID3PHASH ts_h3`.
    public func authorization(origin: String = "https://www.youtube.com", now: Date = Date()) -> String? {
        let ts = Int(now.timeIntervalSince1970)
        func hash(_ secret: String?) -> String? {
            guard let secret, !secret.isEmpty else { return nil }
            let digest = Insecure.SHA1.hash(data: Data("\(ts) \(secret) \(origin)".utf8))
            return "\(ts)_" + digest.map { String(format: "%02x", $0) }.joined()
        }
        var parts: [String] = []
        if let h = hash(cookies["SAPISID"] ?? cookies["__Secure-3PAPISID"]) { parts.append("SAPISIDHASH \(h)") }
        if let h = hash(cookies["__Secure-1PAPISID"]) { parts.append("SAPISID1PHASH \(h)") }
        if let h = hash(cookies["__Secure-3PAPISID"]) { parts.append("SAPISID3PHASH \(h)") }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// Applies `Set-Cookie` rotations (YouTube refreshes some cookies).
    public mutating func merge(setCookieHeaders headers: [String: String], url: URL) -> Bool {
        let fresh = HTTPCookie.cookies(withResponseHeaderFields: headers, for: url)
        var changed = false
        for cookie in fresh where cookie.domain.contains("youtube.com") {
            if let expires = cookie.expiresDate, expires < Date() {
                if cookies.removeValue(forKey: cookie.name) != nil { changed = true }
            } else if cookies[cookie.name] != cookie.value {
                cookies[cookie.name] = cookie.value
                changed = true
            }
        }
        return changed
    }
}
