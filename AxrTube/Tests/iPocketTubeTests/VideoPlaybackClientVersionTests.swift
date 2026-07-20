import Foundation
import Testing
@testable import iPocketTubeCore

// MARK: - VideoPlaybackClientVersionTests

@Suite("iOS InnerTube Client Version")
struct VideoPlaybackClientVersionTests {

    /// The iOS client User-Agent must reflect the actual running OS version, not a
    /// hardcoded "18_3_2" string. This ensures YouTube does not reject stream requests
    /// from devices running iOS 18.7.2, iOS 19, or any future version.
    @Test func iosClientUserAgentReflectsActualOSVersion() {
        let ua = InnerTubeClients.iOS.userAgent
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let expectedVersionFragment = "\(v.majorVersion)_\(v.minorVersion)"
        #expect(ua.contains(expectedVersionFragment),
                "User-Agent '\(ua)' should contain OS version '\(expectedVersionFragment)'")
    }

    /// The hardcoded iOS 18.3.2 version string must no longer appear in the User-Agent.
    @Test func iosClientUserAgentDoesNotContainHardcoded18_3_2() {
        let ua = InnerTubeClients.iOS.userAgent
        #expect(!ua.contains("18_3_2"),
                "User-Agent must not contain hardcoded '18_3_2'; found: \(ua)")
    }

    /// The dynamic OS version string is correctly formatted (underscores, no spaces).
    @Test func iosClientOSVersionStringIsCorrectlyFormatted() {
        let versionString = InnerTubeClients.iOS.currentOSVersionString
        #expect(!versionString.contains("."), "Version string must use underscores, not dots")
        #expect(!versionString.contains(" "), "Version string must not contain spaces")
        let parts = versionString.split(separator: "_")
        #expect(parts.count >= 2, "Version string must have at least major_minor parts")
    }
}

// MARK: - InnerTubeAPI network timeout constant (NW-4-FIX)

@Suite("InnerTubeAPI network configuration")
struct InnerTubeAPINetworkConfigTests {

    @Test("NW-4-FIX: requestTimeoutInterval is 30 seconds")
    func requestTimeoutIntervalIs30Seconds() {
        // Firebase issue 709b3e91: a 2m48s hang occurred because the OS default (60 s)
        // was too permissive for slow/throttled youtubei.googleapis.com requests.
        // This constant is used directly in URLSessionConfiguration.timeoutIntervalForRequest.
        #expect(InnerTubeAPI.requestTimeoutInterval == 30,
                "NW-4-FIX: timeout must be 30 s — do not lower without checking 709b3e91")
    }
}
