import Foundation
import Testing
@testable import iPocketTubeCore

// MARK: - HLSManifestParserTests

@Suite("HLS Manifest Parser")
struct HLSManifestParserTests {

    private let base = URL(string: "https://cdn.example.com/hls/")!

    /// parseHLSVariantURLsForLanguage / parseHLSAllVariants / parseHLSBestVariant resolve
    /// relative URIs against `baseURL.deletingLastPathComponent()` — i.e. `baseURL` is the
    /// master manifest's own URL, not its containing directory.
    private let masterURL = URL(string: "https://cdn.example.com/hls/master.m3u8")!

    // MARK: - Empty / malformed

    @Test("empty manifest returns empty dictionary")
    func parseHLS_emptyManifest_returnsEmpty() {
        let result = parseHLSMasterManifest("", baseURL: base)
        #expect(result.isEmpty)
    }

    @Test("manifest with only tags but no URI lines returns empty")
    func parseHLS_onlyTags_returnsEmpty() {
        let manifest = """
        #EXTM3U
        #EXT-X-VERSION:3
        """
        let result = parseHLSMasterManifest(manifest, baseURL: base)
        #expect(result.isEmpty)
    }

    @Test("malformed STREAM-INF lines without URI are skipped")
    func parseHLS_malformedLines_skipped() {
        let manifest = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=5000000,RESOLUTION=1920x1080
        #EXT-X-STREAM-INF:BANDWIDTH=3000000,RESOLUTION=1280x720
        https://cdn.example.com/720p.m3u8
        """
        let result = parseHLSMasterManifest(manifest, baseURL: base)
        // Only the 720p entry has a URI immediately following; 1080p has another tag → skipped
        #expect(result[720] != nil)
        #expect(result[1080] == nil)
    }

    // MARK: - Single variant

    @Test("single 1080p variant with absolute URI is parsed")
    func parseHLS_singleVariant1080p_returnsOneEntry() {
        let manifest = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=5000000,RESOLUTION=1920x1080
        https://cdn.example.com/1080p.m3u8
        """
        let result = parseHLSMasterManifest(manifest, baseURL: base)
        #expect(result.count == 1)
        #expect(result[1080] == URL(string: "https://cdn.example.com/1080p.m3u8"))
    }

    // MARK: - Multiple heights

    @Test("multiple heights all returned in the dictionary")
    func parseHLS_multipleHeights_returnsAllHeights() {
        let manifest = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=15000000,RESOLUTION=1920x1080
        https://cdn.example.com/1080p.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=8000000,RESOLUTION=1280x720
        https://cdn.example.com/720p.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=4000000,RESOLUTION=854x480
        https://cdn.example.com/480p.m3u8
        """
        let result = parseHLSMasterManifest(manifest, baseURL: base)
        #expect(result.count == 3)
        #expect(result[1080] != nil)
        #expect(result[720]  != nil)
        #expect(result[480]  != nil)
    }

    // MARK: - Relative vs absolute URIs

    @Test("relative URI is resolved against baseURL")
    func parseHLS_relativeURI_resolvesAgainstBaseURL() {
        let manifest = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=5000000,RESOLUTION=1920x1080
        1080p.m3u8
        """
        let result = parseHLSMasterManifest(manifest, baseURL: base)
        #expect(result[1080] == URL(string: "https://cdn.example.com/hls/1080p.m3u8"))
    }

    @Test("absolute http URI is preserved as-is")
    func parseHLS_absoluteURI_preservesAbsoluteURL() {
        let absolute = "https://other-cdn.example.net/streams/1080p.m3u8"
        let manifest = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=5000000,RESOLUTION=1920x1080
        \(absolute)
        """
        let result = parseHLSMasterManifest(manifest, baseURL: base)
        #expect(result[1080] == URL(string: absolute))
    }

    // MARK: - H.264 vs HEVC codec preference

    @Test("on non-tvOS: HEVC variant at same height is upgraded to H.264 when H.264 follows")
    func parseHLS_hevcAndH264SameHeight_iOS_prefersH264() {
        // YouTube manifests often list HEVC first, then H.264 at the same resolution.
        let manifest = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=6000000,RESOLUTION=1920x1080,CODECS="hvc1.2.4.L123.B0"
        https://cdn.example.com/1080p_hevc.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=5000000,RESOLUTION=1920x1080,CODECS="avc1.640028"
        https://cdn.example.com/1080p_h264.m3u8
        """
        let result = parseHLSMasterManifest(manifest, baseURL: base)
        #expect(result[1080] != nil)
        // On iOS/macOS the H.264 variant must win; on tvOS the first-seen (HEVC) wins.
#if os(tvOS)
        #expect(result[1080] == URL(string: "https://cdn.example.com/1080p_hevc.m3u8"),
                "tvOS: keeps first-seen HEVC variant")
#else
        #expect(result[1080] == URL(string: "https://cdn.example.com/1080p_h264.m3u8"),
                "iOS/macOS: upgrades to H.264 variant for broader compatibility")
#endif
    }

    @Test("H.264 first, HEVC second: H.264 is not downgraded")
    func parseHLS_h264First_notDowngradedToHEVC() {
        let manifest = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=5000000,RESOLUTION=1920x1080,CODECS="avc1.640028"
        https://cdn.example.com/1080p_h264.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=6000000,RESOLUTION=1920x1080,CODECS="hvc1.2.4.L123.B0"
        https://cdn.example.com/1080p_hevc.m3u8
        """
        let result = parseHLSMasterManifest(manifest, baseURL: base)
        // H.264 came first; HEVC must not overwrite it on any platform.
        #expect(result[1080] == URL(string: "https://cdn.example.com/1080p_h264.m3u8"))
    }

    // MARK: - parseHLSVariantURLsForLanguage

    @Test("parseHLSVariantURLsForLanguage: nil contentID returns only variants without YT-EXT-AUDIO-CONTENT-ID")
    func parseHLSVariantURLsForLanguage_nilContentID_returnsOriginalOnly() {
        let manifest = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=5000000,RESOLUTION=1920x1080
        original_1080p.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=5000000,RESOLUTION=1280x720,YT-EXT-AUDIO-CONTENT-ID="es-ES.1"
        dubbed_720p.m3u8
        """
        let result = parseHLSVariantURLsForLanguage(nil, from: manifest, baseURL: masterURL)
        #expect(result[1080] == URL(string: "https://cdn.example.com/hls/original_1080p.m3u8"))
        #expect(result[720] == nil)
    }

    @Test("parseHLSVariantURLsForLanguage: matching contentID returns only that dubbed track's variants")
    func parseHLSVariantURLsForLanguage_matchingContentID_returnsDubbedTrack() {
        let manifest = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=5000000,RESOLUTION=1920x1080
        original_1080p.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=5000000,RESOLUTION=1920x1080,YT-EXT-AUDIO-CONTENT-ID="es-ES.1"
        dubbed_1080p.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=2000000,RESOLUTION=854x480,YT-EXT-AUDIO-CONTENT-ID="es-ES.1"
        dubbed_480p.m3u8
        """
        let result = parseHLSVariantURLsForLanguage("es-ES.1", from: manifest, baseURL: masterURL)
        #expect(result.count == 2)
        #expect(result[1080] == URL(string: "https://cdn.example.com/hls/dubbed_1080p.m3u8"))
        #expect(result[480] == URL(string: "https://cdn.example.com/hls/dubbed_480p.m3u8"))
    }

    @Test("parseHLSVariantURLsForLanguage: contentID with no matching variants returns empty")
    func parseHLSVariantURLsForLanguage_noMatch_returnsEmpty() {
        let manifest = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=5000000,RESOLUTION=1920x1080
        original_1080p.m3u8
        """
        let result = parseHLSVariantURLsForLanguage("fr-FR.1", from: manifest, baseURL: base)
        #expect(result.isEmpty)
    }

    // MARK: - parseHLSAllVariants

    @Test("parseHLSAllVariants: empty manifest returns empty")
    func parseHLSAllVariants_emptyManifest_returnsEmpty() {
        #expect(parseHLSAllVariants(from: "", baseURL: base).isEmpty)
    }

    @Test("parseHLSAllVariants: returns one URL per height, first entry wins")
    func parseHLSAllVariants_multipleHeights_firstEntryPerHeightWins() {
        let manifest = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=15000000,RESOLUTION=1920x1080
        first_1080p.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=14000000,RESOLUTION=1920x1080
        second_1080p.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=8000000,RESOLUTION=1280x720
        720p.m3u8
        """
        let result = parseHLSAllVariants(from: manifest, baseURL: masterURL)
        #expect(result.count == 2)
        #expect(result[1080] == URL(string: "https://cdn.example.com/hls/first_1080p.m3u8"))
        #expect(result[720] == URL(string: "https://cdn.example.com/hls/720p.m3u8"))
    }

    @Test("parseHLSAllVariants: relative URI is resolved against baseURL")
    func parseHLSAllVariants_relativeURI_resolvesAgainstBaseURL() {
        let manifest = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=5000000,RESOLUTION=1920x1080
        1080p.m3u8
        """
        let result = parseHLSAllVariants(from: manifest, baseURL: masterURL)
        #expect(result[1080] == URL(string: "https://cdn.example.com/hls/1080p.m3u8"))
    }

    // MARK: - parseHLSBestVariant

    @Test("parseHLSBestVariant: returns nil when no variant meets minHeight")
    func parseHLSBestVariant_noneMeetMinHeight_returnsNil() {
        let manifest = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=2000000,RESOLUTION=854x480
        480p.m3u8
        """
        let result = parseHLSBestVariant(from: manifest, baseURL: base, minHeight: 720)
        #expect(result == nil)
    }

    @Test("parseHLSBestVariant: selects the highest height at or above minHeight")
    func parseHLSBestVariant_selectsHighestAboveMinHeight() {
        let manifest = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=2000000,RESOLUTION=854x480
        480p.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=8000000,RESOLUTION=1280x720
        720p.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=15000000,RESOLUTION=1920x1080
        1080p.m3u8
        """
        let result = parseHLSBestVariant(from: manifest, baseURL: masterURL, minHeight: 720)
        #expect(result == URL(string: "https://cdn.example.com/hls/1080p.m3u8"))
    }

    @Test("parseHLSBestVariant: relative URI is resolved against baseURL")
    func parseHLSBestVariant_relativeURI_resolvesAgainstBaseURL() {
        let manifest = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=15000000,RESOLUTION=1920x1080
        1080p.m3u8
        """
        let result = parseHLSBestVariant(from: manifest, baseURL: masterURL, minHeight: 0)
        #expect(result == URL(string: "https://cdn.example.com/hls/1080p.m3u8"))
    }
}
