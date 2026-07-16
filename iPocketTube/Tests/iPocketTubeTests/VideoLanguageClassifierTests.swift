import Foundation
import Testing
@testable import iPocketTubeCore

@Suite("Russian-only search evidence")
struct VideoLanguageClassifierTests {
    private actor LoadCounter {
        private(set) var count = 0
        func next() -> VideoLanguageEvidence {
            count += 1
            return VideoLanguageEvidence(defaultAudioLanguage: "ru")
        }
    }

    @Test("Russian audio evidence passes regardless of query or title language")
    func russianAudioPasses() {
        let evidence = VideoLanguageEvidence(audioLanguages: ["ru-RU"])
        #expect(VideoLanguageClassifier.verdict(for: evidence) == .russian)
        #expect(VideoLanguageClassifier.includes(evidence: evidence, preference: .russian))
    }

    @Test("Explicit English audio rejects a Russian title signal")
    func englishAudioRejects() {
        let evidence = VideoLanguageEvidence(defaultAudioLanguage: "en-US", manualCaptionLanguages: ["ru"])
        #expect(VideoLanguageClassifier.verdict(for: evidence) == .nonRussian)
        #expect(!VideoLanguageClassifier.includes(evidence: evidence, preference: .russian))
    }

    @Test("Unknown and translated captions do not pass strict mode")
    func unknownRejects() {
        let evidence = VideoLanguageEvidence(manualCaptionLanguages: ["ru"])
        #expect(VideoLanguageClassifier.verdict(for: evidence) == .unknown)
        #expect(!VideoLanguageClassifier.includes(evidence: evidence, preference: .russian))
        #expect(VideoLanguageClassifier.includes(evidence: evidence, preference: .unrestricted))
    }

    @Test("Player metadata parser recognizes audio tracks and ASR captions")
    func playerMetadataParser() {
        let fixture: [String: Any] = [
            "streamingData": [
                "adaptiveFormats": [
                    ["audioTrack": ["id": "ru.4", "displayName": "Русский", "audioIsDefault": true]],
                ],
            ],
            "captions": [
                "playerCaptionsTracklistRenderer": [
                    "captionTracks": [
                        ["languageCode": "ru", "kind": "asr", "vssId": "a.ru"],
                        ["languageCode": "en", "vssId": ".en"],
                    ],
                ],
            ],
        ]
        let evidence = VideoLanguageEvidenceParser.parse(fixture)
        #expect(evidence.defaultAudioLanguage == "ru")
        #expect(evidence.audioLanguages.contains("ru"))
        #expect(evidence.automaticCaptionLanguages == ["ru"])
        #expect(evidence.manualCaptionLanguages == ["en"])
    }

    @Test("Setting defaults on and survives round trip")
    func settingPersistence() throws {
        var settings = AppSettings()
        #expect(settings.russianOnlySearchEnabled)
        settings.russianOnlySearchEnabled = false
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(!decoded.russianOnlySearchEnabled)
    }

    @Test("Evidence cache coalesces concurrent lookups by video ID")
    func cacheDeduplicates() async {
        let cache = VideoLanguageEvidenceCache(ttl: 60)
        let counter = LoadCounter()
        let id = "cache-\(UUID().uuidString)"
        async let first = cache.evidence(for: id) { await counter.next() }
        async let second = cache.evidence(for: id) { await counter.next() }
        let values = await [first, second]

        #expect(values.allSatisfy { $0.defaultAudioLanguage == "ru" })
        #expect(await counter.count == 1)
    }
}
