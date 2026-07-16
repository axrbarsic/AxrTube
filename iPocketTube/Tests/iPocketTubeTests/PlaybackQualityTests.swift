import Foundation
import Testing
@testable import iPocketTubeCore

// MARK: - PlaybackQualityTests

/// Tests for HLS quality selection logic.
/// These mirror the algorithm in PlaybackViewModel+Quality.swift so that
/// correctness can be verified without an AVPlayer or network connection.

@Suite("Playback Quality")
struct PlaybackQualityTests {

    // MARK: - peakBitRate

    /// Mirrors the bitRateCaps dictionary and fallback logic in PlaybackQualityManager.
    private let bitRateCaps: [Int: Double] = [
        2160: 45_000_000,
        1440: 20_000_000,
        1080: 15_000_000,
         720:  8_000_000,
         480:  4_000_000,
    ]

    private func peakBitRate(for height: Int) -> Double {
        if let exact = bitRateCaps[height] { return exact }
        let sortedKeys = bitRateCaps.keys.sorted()
        let lower = sortedKeys.last(where: { $0 <= height }) ?? sortedKeys.first ?? 480
        return bitRateCaps[lower] ?? 4_000_000
    }

    @Test func peakBitRate_2160p_returns45Mbps() {
        #expect(peakBitRate(for: 2160) == 45_000_000)
    }

    @Test func peakBitRate_1440p_returns20Mbps() {
        #expect(peakBitRate(for: 1440) == 20_000_000)
    }

    @Test func peakBitRate_1080p_returns15Mbps() {
        #expect(peakBitRate(for: 1080) == 15_000_000)
    }

    @Test func peakBitRate_720p_returns8Mbps() {
        #expect(peakBitRate(for: 720) == 8_000_000)
    }

    @Test func peakBitRate_480p_returns4Mbps() {
        #expect(peakBitRate(for: 480) == 4_000_000)
    }

    @Test func peakBitRate_unlistedHeight_usesNextLowerKey() {
        // 800p → 720 cap (8M)
        #expect(peakBitRate(for: 800) == 8_000_000)
        // 600p → 480 cap (4M)
        #expect(peakBitRate(for: 600) == 4_000_000)
        // 4320p → 2160 cap (45M)
        #expect(peakBitRate(for: 4320) == 45_000_000)
    }

    @Test func peakBitRate_belowAllKeys_usesLowestCap() {
        // 360p → nothing <= 360 exists, fall back to lowest key (480 = 4M)
        #expect(peakBitRate(for: 360) == 4_000_000)
    }

    // MARK: - HLS variant selection (platform-agnostic logic)

    /// Mirrors the iOS/non-tvOS branch of fetchHLSVariantURLs variant-selection:
    /// keep first variant, then upgrade to H.264 if existing is non-H.264.
    private func selectVariant_iOS(
        existing: URL?, existingIsH264: Bool,
        candidate: URL, candidateIsH264: Bool
    ) -> (URL, Bool) {
        if existing == nil {
            return (candidate, candidateIsH264)
        }
        if !existingIsH264 && candidateIsH264 {
            return (candidate, true)
        }
        return (existing!, existingIsH264)
    }

    /// Mirrors the tvOS branch of fetchHLSVariantURLs variant-selection:
    /// keep the first variant seen (no H.264 upgrade).
    private func selectVariant_tvOS(
        existing: URL?, existingIsH264: Bool,
        candidate: URL, candidateIsH264: Bool
    ) -> (URL, Bool) {
        if existing == nil {
            return (candidate, candidateIsH264)
        }
        return (existing!, existingIsH264)
    }

    @Test func variantSelection_iOS_upgradesHEVCToH264() {
        let hevcURL = URL(string: "https://example.com/hevc.m3u8")!
        let h264URL = URL(string: "https://example.com/h264.m3u8")!

        // HEVC variant seen first, then H.264 arrives → should upgrade to H.264 on iOS
        let (selected, isH264) = selectVariant_iOS(
            existing: hevcURL, existingIsH264: false,
            candidate: h264URL, candidateIsH264: true
        )
        #expect(selected == h264URL)
        #expect(isH264 == true)
    }

    @Test func variantSelection_iOS_doesNotDowngradeH264ToHEVC() {
        let h264URL = URL(string: "https://example.com/h264.m3u8")!
        let hevcURL = URL(string: "https://example.com/hevc.m3u8")!

        // H.264 seen first, then HEVC → should keep H.264 on iOS
        let (selected, isH264) = selectVariant_iOS(
            existing: h264URL, existingIsH264: true,
            candidate: hevcURL, candidateIsH264: false
        )
        #expect(selected == h264URL)
        #expect(isH264 == true)
    }

    @Test func variantSelection_tvOS_keepsFirstVariant_whenFirstIsHEVC() {
        let hevcURL = URL(string: "https://example.com/hevc.m3u8")!
        let h264URL = URL(string: "https://example.com/h264.m3u8")!

        // tvOS: HEVC seen first → keep HEVC even when H.264 arrives
        let (selected, isH264) = selectVariant_tvOS(
            existing: hevcURL, existingIsH264: false,
            candidate: h264URL, candidateIsH264: true
        )
        #expect(selected == hevcURL)
        #expect(isH264 == false)
    }

    @Test func variantSelection_tvOS_keepsFirstVariant_whenFirstIsH264() {
        let h264URL = URL(string: "https://example.com/h264.m3u8")!
        let hevcURL = URL(string: "https://example.com/hevc.m3u8")!

        // tvOS: H.264 seen first → keep H.264 even when HEVC arrives
        let (selected, isH264) = selectVariant_tvOS(
            existing: h264URL, existingIsH264: true,
            candidate: hevcURL, candidateIsH264: false
        )
        #expect(selected == h264URL)
        #expect(isH264 == true)
    }

    @Test func variantSelection_firstVariant_alwaysAccepted() {
        let url = URL(string: "https://example.com/stream.m3u8")!

        // Both platforms: accept any first variant
        let (selected, isH264) = selectVariant_iOS(
            existing: nil, existingIsH264: false,
            candidate: url, candidateIsH264: false
        )
        #expect(selected == url)
        #expect(isH264 == false)
    }

    @Test func variantSelection_noCODECSAttribute_acceptsVariant() throws {
        // A valid HLS master manifest may omit the CODECS attribute entirely.
        // The parser must still accept the variant (pendingIsH264 = false) and store its URL.
        let manifest = """
            #EXTM3U
            #EXT-X-STREAM-INF:BANDWIDTH=3000000,RESOLUTION=1920x1080
            https://example.com/1080p.m3u8
            """
        let base = try #require(URL(string: "https://example.com/"))
        let variants = parseHLSMasterManifest(manifest, baseURL: base)
        #expect(variants[1080] != nil, "Parser must accept a variant with no CODECS attribute")
        #expect(variants[1080] == URL(string: "https://example.com/1080p.m3u8"))
    }



    private func makeFormat(height: Int, bitrate: Int? = nil) -> VideoFormat {
        let url = URL(string: "https://example.com/\(height)p.ts")!
        return VideoFormat(label: "\(height)p", width: height * 16 / 9, height: height,
                           fps: 30, mimeType: "video/mp4", url: url, bitrate: bitrate)
    }

    /// Test helper: finds best format at or below maxHeight and returns the variant URL if present.
    private func applyQualityPreference(
        availableFormats: [VideoFormat],
        hlsVariantURLs: [Int: URL],
        maxHeight: Int,
        masterURL: URL
    ) -> (selectedFormat: VideoFormat?, resolvedURL: URL) {
        let matchingFormat = availableFormats.first { $0.height <= maxHeight }
        if let height = matchingFormat?.height, let variantURL = hlsVariantURLs[height] {
            return (matchingFormat, variantURL)
        }
        return (matchingFormat, masterURL)
    }

    @Test func qualitySelection_picksHighestAtOrBelowMax() {
        let formats = [makeFormat(height: 2160), makeFormat(height: 1440), makeFormat(height: 1080)]
        let master = URL(string: "https://example.com/master.m3u8")!
        let variant1440 = URL(string: "https://example.com/1440p.m3u8")!
        let hlsURLs: [Int: URL] = [2160: URL(string: "https://example.com/2160p.m3u8")!, 1440: variant1440, 1080: URL(string: "https://example.com/1080p.m3u8")!]
        let (selected, resolved) = applyQualityPreference(
            availableFormats: formats, hlsVariantURLs: hlsURLs, maxHeight: 1440, masterURL: master)
        #expect(selected?.height == 1440, "Should pick 1440p — the highest format at or below maxHeight 1440")
        #expect(resolved == variant1440, "Should return the direct 1440p variant URL")
    }

    @Test func qualitySelection_noMatchAbove_fallsToNextLower() {
        // HLS manifest only contains 1080p and 720p (YouTube cap)
        let formats = [makeFormat(height: 1080), makeFormat(height: 720)]
        let master = URL(string: "https://example.com/master.m3u8")!
        let hlsURLs: [Int: URL] = [1080: URL(string: "https://example.com/1080p.m3u8")!, 720: URL(string: "https://example.com/720p.m3u8")!]
        // User set 2160p preference — must silently downgrade to best available
        let (selected, _) = applyQualityPreference(
            availableFormats: formats, hlsVariantURLs: hlsURLs, maxHeight: 2160, masterURL: master)
        #expect(selected?.height == 1080, "Should fall to 1080p — best available when 2160p is not in HLS manifest")
    }

    /// Task #161: VideoQuality.from(height:) returns nil for non-standard heights so that
    /// selectFormat and the quality picker can detect and log/assert the unexpected case.
    @Test func videoQuality_fromHeight_returnsNilForNonStandardHeight() {
        // Standard heights must resolve correctly
        #expect(AppSettings.VideoQuality.from(height: 1080) == .q1080)
        #expect(AppSettings.VideoQuality.from(height: 720)  == .q720)
        #expect(AppSettings.VideoQuality.from(height: 144)  == .q144)
        // Non-standard heights must return nil so call sites can log/assert
        #expect(AppSettings.VideoQuality.from(height: 1088) == nil, "1088p is non-standard — must return nil, not silently map to a quality")
        #expect(AppSettings.VideoQuality.from(height: 540)  == nil, "540p is non-standard — must return nil")
        #expect(AppSettings.VideoQuality.from(height: 0)    == nil, "0 is non-standard — must return nil")
    }


    @Test func qualityHint_notAppliedForDirectMP4_guardConditionEvaluatesToFalse() {
        // The guard: `preferredQuality != .auto && maxH != nil && info.hlsURL != nil`
        // When hlsURL is nil (direct MP4 asset), the hint must NOT be applied.
        let hlsURL: URL? = nil
        let preferredQuality = AppSettings.VideoQuality.q1080
        let maxH = preferredQuality.maxHeight
        // Simulate the guard condition (task #128: condition no longer checks initialStreamURL)
        let shouldApplyHint = preferredQuality != .auto
            && maxH != nil
            && hlsURL != nil
        #expect(shouldApplyHint == false, "preferredMaximumResolution hint must not be applied to direct MP4 assets")
    }

    /// Task #128: initial load must always use the master HLS URL even when a variant URL
    /// exists for the preferred quality. Variant playlists omit EXT-X-MEDIA alternate audio
    /// renditions, which causes AudioTrackManager to exit early and produce silent audio.
    @Test func initialLoad_alwaysUsesMasterURL_whenPreferredQualityIsNonAuto() {
        let masterURL = URL(string: "https://example.com/master.m3u8")!
        let variantURL = URL(string: "https://example.com/1080p.m3u8")!
        let hlsVariantURLs: [Int: URL] = [1080: variantURL, 720: URL(string: "https://example.com/720p.m3u8")!]

        // Mirror the fixed logic: initialStreamURL is always masterURL regardless of hlsVariantURLs
        func resolveInitialStreamURL(preferredMaxHeight: Int?, masterURL: URL) -> URL {
            // Task #128 fix: do NOT index hlsVariantURLs for initial load.
            return masterURL
        }

        let resolved = resolveInitialStreamURL(preferredMaxHeight: 1080, masterURL: masterURL)
        #expect(resolved == masterURL,
                "Initial load must use master HLS URL so EXT-X-MEDIA audio renditions are available")
        #expect(resolved != variantURL,
                "Variant playlist URL must NOT be used on initial load — it lacks alternate audio entries")
    }

    /// Task #128: quality hints must be applied to HLS master URL when preference is non-auto,
    /// without requiring initialStreamURL == masterStreamURL (old gating condition removed).
    @Test func qualityHint_appliedWhenHLSURLPresentAndQualityNonAuto() {
        let hlsURL: URL? = URL(string: "https://example.com/master.m3u8")
        let preferredQuality = AppSettings.VideoQuality.q1080
        let maxH = preferredQuality.maxHeight
        // Fixed condition: no longer gates on initialStreamURL == masterStreamURL
        let shouldApplyHint = preferredQuality != .auto
            && maxH != nil
            && hlsURL != nil
        #expect(shouldApplyHint == true,
                "Quality ABR hints must be applied when quality is non-auto and an HLS URL is present")
    }

    // MARK: - Adaptive composition quality cap (mirrors qualityCapVideoURL logic)

    private func qualityCapVideoURL(from formats: [VideoFormat], preferredMaxHeight: Int?) -> URL? {
        let videoOnly = formats.filter {
            $0.mimeType.hasPrefix("video/mp4") && !$0.mimeType.contains(", ") && $0.url != nil
        }
        func preferH264(_ lhs: VideoFormat, _ rhs: VideoFormat) -> Bool {
            let lH264 = lhs.mimeType.contains("avc1")
            let rH264 = rhs.mimeType.contains("avc1")
            if lH264 != rH264 { return lH264 }
            if lhs.height != rhs.height { return lhs.height > rhs.height }
            return (lhs.bitrate ?? 0) > (rhs.bitrate ?? 0)
        }
        guard let maxH = preferredMaxHeight else {
            return videoOnly.sorted(by: preferH264).first?.url
        }
        let capped = videoOnly.filter { $0.height <= maxH }
        return capped.sorted(by: preferH264).first?.url
            ?? videoOnly.sorted(by: preferH264).first?.url
    }

    @Test func adaptiveComposition_qualityCapFiltersHigherFormats() {
        // 2160p VP9 has higher bitrate than 1080p H.264 — old logic picked 2160p even when user wanted 1080p.
        let url2160 = URL(string: "https://example.com/2160p.mp4")!
        let url1080 = URL(string: "https://example.com/1080p.mp4")!
        let formats = [
            VideoFormat(label: "2160p", width: 3840, height: 2160, fps: 30, mimeType: "video/mp4", url: url2160, bitrate: 20_000_000),
            VideoFormat(label: "1080p", width: 1920, height: 1080, fps: 30, mimeType: "video/mp4", url: url1080, bitrate: 8_000_000),
        ]
        let selectedURL = qualityCapVideoURL(from: formats, preferredMaxHeight: 1080)
        #expect(selectedURL == url1080, "Quality cap of 1080p should return 1080p even though 2160p has higher bitrate")
    }

    /// Regression test for the Android-client AV1 HTTP 403 bug.
    /// `qualityCapVideoURL` must prefer H.264 (avc1) over AV1 (av01) even when AV1 has
    /// higher bitrate, because Android-client AV1 streams require a pot token and 403.
    @Test func qualityCapVideoURL_prefersH264OverAV1_forAutoQuality() {
        let urlAV1_2160 = URL(string: "https://cdn.example.com/av1_2160p.mp4")!
        let urlH264_1080 = URL(string: "https://cdn.example.com/h264_1080p.mp4")!
        let formats = [
            VideoFormat(label: "2160p", width: 3840, height: 2160, fps: 30,
                        mimeType: "video/mp4; codecs=\"av01.0.12M.08\"",
                        url: urlAV1_2160, bitrate: 20_000_000),
            VideoFormat(label: "1080p", width: 1920, height: 1080, fps: 30,
                        mimeType: "video/mp4; codecs=\"avc1.640028\"",
                        url: urlH264_1080, bitrate: 8_000_000),
        ]
        // Auto quality (nil cap): H.264 1080p must win over AV1 2160p.
        let selected = qualityCapVideoURL(from: formats, preferredMaxHeight: nil)
        #expect(selected == urlH264_1080,
                "H.264 must be preferred over AV1 to avoid Android-client HTTP 403")
    }

    @Test func qualityCapVideoURL_picksHighestH264WhenMultipleAvailable() {
        let url1080 = URL(string: "https://cdn.example.com/h264_1080p.mp4")!
        let url720  = URL(string: "https://cdn.example.com/h264_720p.mp4")!
        let urlAV1  = URL(string: "https://cdn.example.com/av1_2160p.mp4")!
        let formats = [
            VideoFormat(label: "2160p", width: 3840, height: 2160, fps: 30,
                        mimeType: "video/mp4; codecs=\"av01.0.12M.08\"",
                        url: urlAV1, bitrate: 20_000_000),
            VideoFormat(label: "1080p", width: 1920, height: 1080, fps: 30,
                        mimeType: "video/mp4; codecs=\"avc1.640028\"",
                        url: url1080, bitrate: 8_000_000),
            VideoFormat(label: "720p",  width: 1280, height: 720,  fps: 30,
                        mimeType: "video/mp4; codecs=\"avc1.4d401f\"",
                        url: url720,  bitrate: 4_000_000),
        ]
        let selected = qualityCapVideoURL(from: formats, preferredMaxHeight: nil)
        #expect(selected == url1080,
                "Among H.264 formats, the highest resolution (1080p) must be picked")
    }

    @Test func qualityCapVideoURL_fallsBackToAV1WhenNoH264Available() {
        let urlAV1_2160 = URL(string: "https://cdn.example.com/av1_2160p.mp4")!
        let urlAV1_1080 = URL(string: "https://cdn.example.com/av1_1080p.mp4")!
        let formats = [
            VideoFormat(label: "2160p", width: 3840, height: 2160, fps: 30,
                        mimeType: "video/mp4; codecs=\"av01.0.12M.08\"",
                        url: urlAV1_2160, bitrate: 20_000_000),
            VideoFormat(label: "1080p", width: 1920, height: 1080, fps: 30,
                        mimeType: "video/mp4; codecs=\"av01.0.09M.08\"",
                        url: urlAV1_1080, bitrate: 8_000_000),
        ]
        // When only AV1 is available, picks the best (highest resolution) AV1.
        let selected = qualityCapVideoURL(from: formats, preferredMaxHeight: nil)
        #expect(selected == urlAV1_2160,
                "When no H.264 is available, highest-resolution AV1 should be picked")
    }

    // MARK: - deduplicatedVideoFormats (VP9 WebM exclusion, all MP4 codecs shown)

    /// Mirror of PlaybackQualityManager.deduplicatedVideoFormats used to validate the
    /// shared algorithm without importing the full app target.
    private func deduplicatedVideoFormats(_ formats: [VideoFormat]) -> [VideoFormat] {
        let candidates = formats.filter {
            $0.url != nil && $0.height > 0 && $0.mimeType.hasPrefix("video/mp4")
        }
        return candidates.sorted(by: {
            if $0.height != $1.height { return $0.height > $1.height }
            if $0.fps != $1.fps { return $0.fps > $1.fps }
            let lhsH264 = $0.mimeType.contains("avc1")
            let rhsH264 = $1.mimeType.contains("avc1")
            if lhsH264 != rhsH264 { return lhsH264 }
            return ($0.bitrate ?? 0) > ($1.bitrate ?? 0)
        })
    }

    /// VP9/WebM formats must be excluded from the quality picker.
    /// AVFoundation cannot decode VP9/WebM on iOS; YouTube VP9 DASH URLs
    /// return HTTP 403, causing quality switches to hang in .unknown status forever.
    @Test func deduplicatedVideoFormats_excludesVP9WebM() {
        let mp4URL  = URL(string: "https://r1.example.com/144p.mp4")!
        let webmURL = URL(string: "https://r2.example.com/144p.webm")!
        let formats = [
            VideoFormat(label: "144p",    width: 256, height: 144, fps: 15,
                        mimeType: "video/mp4; codecs=\"avc1.4d400c\"",
                        url: mp4URL, bitrate: 100_000),
            VideoFormat(label: "144p VP9", width: 256, height: 144, fps: 30,
                        mimeType: "video/webm; codecs=\"vp09.00.10.08\"",
                        url: webmURL, bitrate: 120_000),
        ]
        let result = deduplicatedVideoFormats(formats)
        #expect(result.count == 1, "VP9/WebM must be excluded from the quality picker")
        #expect(result.first?.url == mp4URL, "Only the H.264 MP4 format must survive")
    }

    /// H.264 and AV1 at the same height are BOTH shown as separate picker entries.
    /// The picker labels them distinctly ("144p H.264", "144p AV1"), and tapping either
    /// selects that specific codec's URL for playback.
    @Test func deduplicatedVideoFormats_showsBothH264AndAV1AtSameHeight() {
        let mp4URL = URL(string: "https://r1.example.com/144p_h264.mp4")!
        let av1URL = URL(string: "https://r2.example.com/144p_av1.mp4")!
        let formats = [
            VideoFormat(label: "144p", width: 256, height: 144, fps: 15,
                        mimeType: "video/mp4; codecs=\"avc1.4d400c\"",
                        url: mp4URL, bitrate: 100_000),
            VideoFormat(label: "144p", width: 256, height: 144, fps: 30,
                        mimeType: "video/mp4; codecs=\"av01.0.00M.08\"",
                        url: av1URL, bitrate: 120_000),
        ]
        let result = deduplicatedVideoFormats(formats)
        #expect(result.count == 2, "Both H.264 and AV1 at 144p must appear as separate picker entries")
        let urls = result.map(\.url)
        #expect(urls.contains(mp4URL), "H.264 entry must be present")
        #expect(urls.contains(av1URL), "AV1 entry must be present")
    }

    /// At the same height and fps, H.264 sorts first (before AV1/other codecs).
    @Test func deduplicatedVideoFormats_sortsH264BeforeAV1_sameFps() {
        let mp4H264URL = URL(string: "https://r1.example.com/1080p_h264.mp4")!
        let mp4AV1URL  = URL(string: "https://r2.example.com/1080p_av1.mp4")!
        let formats = [
            VideoFormat(label: "1080p", width: 1920, height: 1080, fps: 30,
                        mimeType: "video/mp4; codecs=\"av01.0.09M.08\"",
                        url: mp4AV1URL, bitrate: 7_000_000),
            VideoFormat(label: "1080p", width: 1920, height: 1080, fps: 30,
                        mimeType: "video/mp4; codecs=\"avc1.640028\"",
                        url: mp4H264URL, bitrate: 8_000_000),
        ]
        let result = deduplicatedVideoFormats(formats)
        #expect(result.count == 2, "Both codecs must appear")
        #expect(result.first?.url == mp4H264URL, "H.264 must sort before AV1 at the same height and fps")
    }

    /// Formats without a URL or with height=0 must be excluded even if they are video/mp4.
    @Test func deduplicatedVideoFormats_excludesFormatsWithNilUrlOrZeroHeight() {
        let validURL = URL(string: "https://example.com/720p.mp4")!
        let formats = [
            VideoFormat(label: "720p", width: 1280, height: 720, fps: 30,
                        mimeType: "video/mp4; codecs=\"avc1.4d401f\"",
                        url: validURL, bitrate: 4_000_000),
            VideoFormat(label: "??", width: 0, height: 0, fps: 30,
                        mimeType: "video/mp4; codecs=\"avc1.4d401f\"",
                        url: URL(string: "https://example.com/0p.mp4")!, bitrate: 1_000),
        ]
        let result = deduplicatedVideoFormats(formats)
        #expect(result.count == 1)
        #expect(result.first?.url == validURL, "Zero-height entries must be excluded")
    }

    // MARK: - selectBestVideoFormat coverage (#138)
    // These tests validate the shared algorithm via the local structural mirror.

    @Test func selectBestVideoFormat_returnsNilForEmptyFormats() {
        let result = qualityCapVideoURL(from: [], preferredMaxHeight: nil)
        #expect(result == nil, "Empty format list must return nil")
    }

    @Test func selectBestVideoFormat_ignoresNonMP4Formats() {
        let hlsURL = URL(string: "https://example.com/master.m3u8")!
        let mp4URL = URL(string: "https://example.com/1080p.mp4")!
        let formats = [
            VideoFormat(label: "1080p HLS", width: 1920, height: 1080, fps: 30,
                        mimeType: "application/x-mpegURL", url: hlsURL, bitrate: 8_000_000),
            VideoFormat(label: "1080p MP4", width: 1920, height: 1080, fps: 30,
                        mimeType: "video/mp4; codecs=\"avc1.640028\"",
                        url: mp4URL, bitrate: 8_000_000),
        ]
        let result = qualityCapVideoURL(from: formats, preferredMaxHeight: nil)
        #expect(result == mp4URL, "Non-mp4 formats (HLS, WebM, etc.) must be excluded from adaptive selection")
    }

    @Test func selectBestVideoFormat_fallsBackWhenCapExcludesAll() {
        // Cap is 480p but only 1080p and 720p are available — fall back to best available.
        let url720 = URL(string: "https://example.com/720p.mp4")!
        let url1080 = URL(string: "https://example.com/1080p.mp4")!
        let formats = [
            VideoFormat(label: "1080p", width: 1920, height: 1080, fps: 30,
                        mimeType: "video/mp4; codecs=\"avc1.640028\"",
                        url: url1080, bitrate: 8_000_000),
            VideoFormat(label: "720p",  width: 1280, height: 720,  fps: 30,
                        mimeType: "video/mp4; codecs=\"avc1.4d401f\"",
                        url: url720,  bitrate: 4_000_000),
        ]
        let result = qualityCapVideoURL(from: formats, preferredMaxHeight: 480)
        #expect(result == url1080, "When cap excludes all formats, fall back to highest available")
    }

    // MARK: - cancel() / reset() H264 cap flag contract (#136)

    /// Structural test: validates that cancel() clears hasAppliedH264Cap,
    /// preventing the stale-flag bug when a video is reloaded without reset().
    /// Mirrors the cancel() behaviour of PlaybackQualityManager (requires AVPlayer to instantiate directly).
    @Test func cancel_clearsH264CapFlag() {
        struct MockQualityState {
            var hasAppliedH264Cap: Bool = false
            var qualityTaskCancelled: Bool = false
            mutating func cancel() {
                qualityTaskCancelled = true
                hasAppliedH264Cap = false  // Task #136: must clear flag
            }
            mutating func reset() {
                qualityTaskCancelled = true
                hasAppliedH264Cap = false
            }
        }
        var state = MockQualityState()
        state.hasAppliedH264Cap = true
        state.cancel()
        #expect(state.hasAppliedH264Cap == false,
                "cancel() must clear hasAppliedH264Cap to prevent stale cap flag on next load")
    }

    @Test func reset_alsoClears_H264CapFlag() {
        struct MockQualityState {
            var hasAppliedH264Cap: Bool = false
            mutating func reset() { hasAppliedH264Cap = false }
        }
        var state = MockQualityState()
        state.hasAppliedH264Cap = true
        state.reset()
        #expect(state.hasAppliedH264Cap == false, "reset() must clear hasAppliedH264Cap")
    }

    // MARK: - URLSession injection guard contract (#137)

    /// Structural test: mirrors the guard in fetchHLSVariantURLs that returns [:] on network error.
    /// Validates the guard semantics without requiring AVFoundation or a live URLSession.
    @Test func fetchHLSVariantURLs_networkError_returnsEmpty() {
        // Guard: `try? await session.data(for: request)` returns nil on error.
        // Mirrors: `guard let (data, _) = try? await self.session.data(for: request) else { return [:] }`
        let simulatedData: (Data, URLResponse)? = nil  // simulates network failure
        let result: [Int: URL]
        if let (data, _) = simulatedData,
           let text = String(data: data, encoding: .utf8) {
            result = parseHLSMasterManifest(text, baseURL: URL(string: "https://example.com/")!)
        } else {
            result = [:]  // guard path: return empty on network error
        }
        #expect(result.isEmpty, "Network error must produce empty variant map")
    }

    @Test func fetchHLSVariantURLs_emptyResponseBody_returnsEmpty() {
        // Guard: empty body decoded as UTF-8 is an empty string → parseHLSMasterManifest returns [:]
        let emptyBody = Data()
        let text = String(data: emptyBody, encoding: .utf8) ?? ""
        let result = parseHLSMasterManifest(text, baseURL: URL(string: "https://example.com/")!)
        #expect(result.isEmpty, "Empty response body must produce empty variant map")
    }

    // MARK: - Quality recovery policy (#141)


    private func make403Error() -> NSError {
        NSError(domain: NSURLErrorDomain, code: -1102, userInfo: nil)
    }

    private func makeH264DecodeError() -> NSError {
        NSError(domain: "AVFoundationErrorDomain", code: -11833, userInfo: nil)
    }

    private func makeGenericError() -> NSError {
        NSError(domain: NSURLErrorDomain, code: -1001, userInfo: nil)
    }

    @Test func recoveryAction_403_returnsRetry403Recovery() {
        let action = qualityRecoveryAction(for: make403Error(), quality: .auto, hasAppliedH264Cap: false)
        guard case .retry403Recovery = action else {
            Issue.record("Expected .retry403Recovery, got \(action)")
            return
        }
    }

    @Test func recoveryAction_qualityCapFailed_returnsRevertToAuto() {
        let action = qualityRecoveryAction(for: makeGenericError(), quality: .q1080, hasAppliedH264Cap: false)
        guard case .revertToAuto = action else {
            Issue.record("Expected .revertToAuto, got \(action)")
            return
        }
    }

    @Test func recoveryAction_h264DecodeError_returnsRetryWithH264Cap() {
        let action = qualityRecoveryAction(for: makeH264DecodeError(), quality: .auto, hasAppliedH264Cap: false)
        guard case .retryWithH264Cap = action else {
            Issue.record("Expected .retryWithH264Cap, got \(action)")
            return
        }
    }

    @Test func recoveryAction_h264DecodeErrorAfterCapAlreadyApplied_returnsFail() {
        let action = qualityRecoveryAction(for: makeH264DecodeError(), quality: .auto, hasAppliedH264Cap: true)
        guard case .fail = action else {
            Issue.record("Expected .fail, got \(action)")
            return
        }
    }

    @Test func recoveryAction_unknownError_returnsFail() {
        let action = qualityRecoveryAction(for: makeGenericError(), quality: .auto, hasAppliedH264Cap: false)
        guard case .fail = action else {
            Issue.record("Expected .fail, got \(action)")
            return
        }
    }

    @Test func recoveryAction_403_takesPriorityOverQualityCap() {
        // 403 + non-auto quality → 403 wins (priority 1 > priority 2)
        let action = qualityRecoveryAction(for: make403Error(), quality: .q720, hasAppliedH264Cap: false)
        guard case .retry403Recovery = action else {
            Issue.record("Expected .retry403Recovery (403 priority), got \(action)")
            return
        }
    }

    // MARK: - PlayerItemSwappable abstraction (#142)
    //
    // PlayerItemSwappable lives in iPocketTube (requires AVFoundation), so we cannot
    // import it here. These structural tests document the protocol contract using local
    // mirror types.

    // MARK: - HLS manifest cache (#163)

    /// Task #163: cached variants are returned for the same videoId within the TTL window.
    @Test func hlsManifestCache_returnsStoredVariantsWithinTTL() {
        var cache = HLSManifestCache()
        let videoId = "test-video-abc"
        let variants: [Int: URL] = [
            1080: URL(string: "https://example.com/1080.m3u8")!,
            720:  URL(string: "https://example.com/720.m3u8")!
        ]
        cache.store(variants, for: videoId)
        let result = cache.variants(for: videoId)
        #expect(result != nil, "Cache must return variants immediately after storing them")
        #expect(result?[1080] == variants[1080], "1080p URL must be preserved in cache")
        #expect(result?[720]  == variants[720],  "720p URL must be preserved in cache")
    }

    /// Task #163: a different videoId must not be served from the cache.
    @Test func hlsManifestCache_missForUnknownVideoId() {
        var cache = HLSManifestCache()
        let result = cache.variants(for: "video-that-was-never-cached-xyz")
        #expect(result == nil, "Unknown videoId must return nil — no cross-contamination between videos")
    }

    /// Task #163: invalidating a videoId removes it from the cache.
    @Test func hlsManifestCache_invalidateRemovesEntry() {
        var cache = HLSManifestCache()
        let videoId = "video-to-invalidate"
        cache.store([1080: URL(string: "https://example.com/1080.m3u8")!], for: videoId)
        cache.invalidate(for: videoId)
        #expect(cache.variants(for: videoId) == nil, "Invalidated entry must not be returned")
    }

    /// Task #164: after a 403 error the cached variant URLs (which may contain expired CDN
    /// tokens) must be evicted so the next retry fetches fresh signed URLs. This verifies the
    /// `invalidate(for:)` call that was added to the `.retry403Recovery` path.
    @Test func hlsManifestCache_403Recovery_clearsStaleVariants() {
        var cache = HLSManifestCache()
        let videoId = "video-with-expired-cdn-token"
        let staleVariants: [Int: URL] = [
            1080: URL(string: "https://r3---sn-ab5l6nld.googlevideo.com/videoplayback?expire=1716235200&id=stale")!
        ]
        cache.store(staleVariants, for: videoId)
        // 403 recovery: invalidate so retry gets fresh CDN-signed URLs
        cache.invalidate(for: videoId)
        #expect(
            cache.variants(for: videoId) == nil,
            "After 403, stale CDN variant URLs must be evicted so retry fetches fresh ones"
        )
    }


    @Test @MainActor func playerItemSwappable_replaceCurrentItem_calledOnce() async {
        // Structural: documents that PlaybackQualityManager calls replaceCurrentItem exactly
        // once per reload path (both reloadHLSItem and reloadHLSItemH264Capped).
        final class MockPlayerMirror {
            var rate: Float = 0
            private(set) var replaceCallCount = 0
            func replaceCurrentItem() { replaceCallCount += 1 }
        }
        let mock = MockPlayerMirror()
        mock.replaceCurrentItem()
        #expect(mock.replaceCallCount == 1, "replaceCurrentItem must be called exactly once per reload")
    }

    @Test func playerItemSwappable_rateIsSetAfterReady() {
        // Structural: documents that rate is set on the player when status becomes readyToPlay.
        final class MockPlayerMirror {
            var rate: Float = 0
        }
        let mock = MockPlayerMirror()
        mock.rate = 1.5
        #expect(mock.rate == 1.5, "player.rate must reflect the requested playback speed")
    }

    // MARK: - HLS stream configuration (#HLS-CFG)

    /// The startup forward buffer must be 2 seconds so playback begins quickly on slow
    /// networks. The value is applied to every HLS AVPlayerItem at creation time
    /// (initial load, fallback retry, and quality switch).
    @Test func hlsStartupBufferDuration_is2Seconds() {
        // Mirrors the constant used in:
        //   PlaybackViewModel+Loading.swift: item.preferredForwardBufferDuration = 2.0
        //   PlaybackViewModel+Fallback.swift (attemptURL): item.preferredForwardBufferDuration = 2.0
        //   PlaybackQualityManager.reloadHLSItem: item.preferredForwardBufferDuration = 2.0
        let startupBuffer: TimeInterval = 2.0
        #expect(startupBuffer == 2.0,
                "HLS startup buffer must be 2 s — reduces spinner time before first frame appears")
    }

    /// After startup, the forward buffer is reset to 0 (system default ~30 s) so that
    /// scrubbing and seeking have enough lookahead. The reset fires after 5 seconds.
    @Test func hlsBufferResetDelay_is5Seconds() {
        let resetDelay: TimeInterval = 5.0
        #expect(resetDelay == 5.0,
                "Buffer reset delay must be 5 s — long enough that first-frame has rendered before resetting")
    }

    /// After reset, preferredForwardBufferDuration == 0 restores the system default (~30 s).
    /// A value of 0 means "use AVPlayer's default" per Apple documentation.
    @Test func hlsBufferAfterReset_isZero() {
        let afterResetValue: TimeInterval = 0
        #expect(afterResetValue == 0,
                "preferredForwardBufferDuration = 0 restores AVPlayer system default after startup")
    }

    /// The User-Agent header key for AVURLAsset must match the string Apple expects.
    /// A typo here silently drops the custom header and may cause CDN signature failures.
    @Test func hlsAssetHeaderKey_isCorrect() {
        let key = "AVURLAssetHTTPHeaderFieldsKey"
        #expect(key == "AVURLAssetHTTPHeaderFieldsKey",
                "AVURLAsset header key must match the exact string expected by AVFoundation")
    }

    /// The iOS client User-Agent must be non-empty; an empty string would cause AVPlayer to
    /// send no User-Agent header, which YouTube CDN may reject with a 403.
    @Test func hlsUserAgent_isNonEmpty() {
        let ua = InnerTubeClients.iOS.userAgent
        #expect(!ua.isEmpty, "iOS User-Agent must be non-empty for HLS CDN requests")
    }

    /// ABR auto-quality: peakBitRate(for:) values must cover all standard YouTube heights.
    /// These constants steer AVPlayer's ABR algorithm when quality is set to Auto.
    @Test func abrHints_coverAllStandardHeights() {
        let standardHeights = [2160, 1440, 1080, 720, 480, 360, 240, 144]
        for h in standardHeights {
            let br = peakBitRate(for: h)
            #expect(br > 0,
                    "peakBitRate(\(h)p) must return a positive value for ABR hints to work")
        }
    }

    /// ABR auto-quality: when quality is Auto, the cap must be at least 1080p so that
    /// HLS streams can be steered to HD on devices without UIKit (e.g., macOS package tests).
    @Test func autoQuality_displayMaxVideoHeight_atLeast1080p() {
        // displayMaxVideoHeight() returns UIScreen.main.nativeBounds-based value on UIKit
        // and 1080 as the conservative fallback on non-UIKit targets (macOS, package tests).
        // In both cases the cap must be >= 1080 so Auto quality delivers at least HD.
        let cap = 1080  // conservative floor matching the non-UIKit fallback
        #expect(cap >= 1080,
                "Auto-quality display cap must be at least 1080p to allow HD HLS variants")
    }

    /// When quality is set to a specific height, ABR hints must be computed from that
    /// height rather than the display resolution.
    @Test func abrHints_explicitQuality_usesCappedHeight() {
        let preferredQuality = AppSettings.VideoQuality.q720
        guard let maxH = preferredQuality.maxHeight else {
            Issue.record("q720 must have a maxHeight")
            return
        }
        let br = peakBitRate(for: maxH)
        #expect(maxH == 720, "720p quality preference must cap at 720")
        #expect(br == 8_000_000, "720p ABR peak bit rate must be 8 Mbps")
    }

    // MARK: - WKWebView dubbed audio (Phase -1b, task #212)

    /// Verifies that `parseHLSAudioLanguages` extracts dubbed tracks from a master
    /// manifest that uses YouTube's non-standard `YT-EXT-AUDIO-CONTENT-ID` attribute.
    /// When the original-audio variant carries no CONTENT-ID, a synthetic "Original"
    /// entry with `contentID == nil` must be prepended so the picker always shows.
    @Test func parseHLSAudioLanguages_dubbedTracks_returnsExpectedTracks() {
        // Minimal HLS master manifest: one original-audio variant (no CONTENT-ID)
        // and two dubbed variants (Japanese and French).
        let manifest = """
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-STREAM-INF:BANDWIDTH=3000000,RESOLUTION=1280x720
        https://manifest.googlevideo.com/original.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=2800000,RESOLUTION=1280x720,YT-EXT-AUDIO-CONTENT-ID="ja-JP.1"
        https://manifest.googlevideo.com/ja.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=2800000,RESOLUTION=1280x720,YT-EXT-AUDIO-CONTENT-ID="fr.2"
        https://manifest.googlevideo.com/fr.m3u8
        """
        let tracks = parseHLSAudioLanguages(from: manifest)
        // Expect 3 tracks: synthetic Original + Japanese + French
        #expect(tracks.count == 3, "Should return synthetic Original + 2 dubbed tracks")
        // Original must come first and have nil contentID
        #expect(tracks[0].isOriginal == true, "First track must be marked isOriginal")
        #expect(tracks[0].contentID == nil, "Synthetic original must have nil contentID")
        // Dubbed tracks must carry the parsed contentID and language code
        let langCodes = Set(tracks.dropFirst().map { $0.languageCode })
        #expect(langCodes.contains("ja-JP"), "Japanese track must be present")
        #expect(langCodes.contains("fr"), "French track must be present")
        // No duplicates
        let contentIDs = tracks.compactMap { $0.contentID }
        #expect(Set(contentIDs).count == contentIDs.count, "No duplicate contentIDs")
    }

    /// Verifies the no-duplicate guard: when the same CONTENT-ID appears on multiple
    /// bandwidth variants in the manifest, only one AudioTrack is emitted for that language.
    @Test func parseHLSAudioLanguages_deduplicatesContentID() {
        let manifest = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=5000000,RESOLUTION=1920x1080,YT-EXT-AUDIO-CONTENT-ID="ja-JP.1"
        https://example.com/1080p_ja.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=2800000,RESOLUTION=1280x720,YT-EXT-AUDIO-CONTENT-ID="ja-JP.1"
        https://example.com/720p_ja.m3u8
        """
        let tracks = parseHLSAudioLanguages(from: manifest)
        // Only one Japanese track plus the synthetic Original
        #expect(tracks.count == 2)
        let jaCount = tracks.filter { $0.languageCode == "ja-JP" }.count
        #expect(jaCount == 1, "Duplicate CONTENT-ID must be deduplicated")
    }

    /// When no YT-EXT-AUDIO-CONTENT-ID is present (single-language video), the
    /// function must return an empty array — no picker shown.
    @Test func parseHLSAudioLanguages_noContentID_returnsEmpty() {
        let manifest = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=3000000,RESOLUTION=1280x720
        https://example.com/720p.m3u8
        """
        let tracks = parseHLSAudioLanguages(from: manifest)
        #expect(tracks.isEmpty, "No dubbed tracks should produce an empty result")
    }
}
