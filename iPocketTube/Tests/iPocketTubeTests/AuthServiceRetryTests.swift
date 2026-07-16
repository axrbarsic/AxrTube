import Foundation
import Testing
@testable import iPocketTubeCore

// MARK: - AuthServiceRetryTests

@Suite("Auth Retry Resilience")
struct AuthServiceRetryTests {

    /// Verifies that InnerTubeAPI is initialised with a URLSession configured for
    /// transient-network resilience: 30 s per-request timeout (NW-4-FIX — Firebase 709b3e91
    /// showed a 2m48s hang at the OS default), a generous resource timeout (60 s), and
    /// waitsForConnectivity so that a momentary offline state does not immediately fail auth requests.
    @Test func innerTubeAPIURLSessionConfiguredForTransientNetworkResilience() async {
        let api = InnerTubeAPI()
        let config = await api.session.configuration
        #expect(config.timeoutIntervalForRequest == 30)
        #expect(config.timeoutIntervalForResource == 60)
        #expect(config.waitsForConnectivity)
    }
}
