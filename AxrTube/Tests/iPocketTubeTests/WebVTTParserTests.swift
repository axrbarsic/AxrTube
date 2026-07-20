import Foundation
import Testing
@testable import iPocketTubeCore

// MARK: - WebVTTParserTests
//
// Tests for WebVTTParser.parseVTT(_:) — a nonisolated public function,
// so tests are synchronous with no simulator or network required.

@Suite("WebVTT Parser")
struct WebVTTParserTests {

    private let parser = WebVTTParser()

    // MARK: - Basic parsing

    @Test("Single cue is parsed correctly")
    func basicCueIsParsed() {
        let vtt = """
        WEBVTT

        00:00:01.000 --> 00:00:03.000
        Hello World
        """
        let cues = parser.parseVTT(vtt)
        #expect(cues.count == 1)
        #expect(cues[0].text == "Hello World")
        #expect(cues[0].startTime == 1.0)
        #expect(cues[0].endTime == 3.0)
    }

    @Test("Multiple cues are all parsed in order")
    func multipleCuesParsed() {
        let vtt = """
        WEBVTT

        00:00:01.000 --> 00:00:02.000
        First

        00:00:03.000 --> 00:00:04.000
        Second

        00:00:05.000 --> 00:00:06.000
        Third
        """
        let cues = parser.parseVTT(vtt)
        #expect(cues.count == 3)
        #expect(cues[0].text == "First")
        #expect(cues[1].text == "Second")
        #expect(cues[2].text == "Third")
    }

    @Test("Empty WEBVTT string produces no cues")
    func emptyVTTReturnsNoCues() {
        let cues = parser.parseVTT("WEBVTT\n\n")
        #expect(cues.isEmpty)
    }

    @Test("Legacy cached cue JSON decodes without word activation metadata")
    func legacyCueJSONStillDecodes() throws {
        let data = Data(#"{"startTime":1,"endTime":3,"text":"Legacy"}"#.utf8)
        let cue = try JSONDecoder().decode(CaptionCue.self, from: data)

        #expect(cue.text == "Legacy")
        #expect(cue.activationTime == nil)
        #expect(cue.effectiveActivationTime == 1)
    }

    // MARK: - Tag stripping

    @Test("Inline VTT tags are stripped from cue text")
    func inlineTagsStripped() {
        let vtt = """
        WEBVTT

        00:00:01.000 --> 00:00:03.000
        <c>Hello</c> <b>World</b>
        """
        let cues = parser.parseVTT(vtt)
        #expect(cues.count == 1)
        #expect(cues[0].text == "Hello World")
    }

    @Test("Timestamp tags are stripped from cue text")
    func timestampTagsStripped() {
        let vtt = """
        WEBVTT

        00:00:01.000 --> 00:00:04.000
        <00:00:01.500>Word <00:00:02.000>by <00:00:02.200>word
        """
        let cues = parser.parseVTT(vtt)
        #expect(cues.count == 1)
        #expect(cues[0].text == "Word by word")
        #expect(abs((cues[0].activationTime ?? 0) - 2.0) < 0.0001)
    }

    @Test("YouTube whitespace service line does not drop the first real cue")
    func leadingServiceLinePreservesFirstCue() {
        let vtt = """
        WEBVTT
        Kind: captions
        Language: en

        00:00:00.000 --> 00:00:02.149 align:start position:0%
        \u{20}
        Kimi<00:00:00.400><c> K3</c><00:00:00.600><c> just</c><00:00:00.700><c> is</c>
        """

        let cues = parser.parseVTT(vtt)

        #expect(cues.count == 1)
        #expect(cues[0].startTime == 0)
        #expect(cues[0].endTime == 2.149)
        #expect(cues[0].text == "Kimi K3 just is")
        #expect(abs((cues[0].activationTime ?? 0) - 0.5) < 0.0001)
    }

    @Test("YouTube word-timed roll-up keeps only new tails and safe activation times")
    func wordTimedRollupIsNormalized() {
        let vtt = """
        WEBVTT

        00:00:00.000 --> 00:00:02.149 align:start position:0%
        \u{20}
        Kimi<00:00:00.400><c> K3</c><00:00:00.960><c> just</c><00:00:01.920><c> is</c>

        00:00:02.149 --> 00:00:02.159 align:start position:0%
        Kimi K3 just is
        \u{20}

        00:00:02.159 --> 00:00:04.550 align:start position:0%
        Kimi K3 just is
        really<00:00:02.480><c> a</c><00:00:03.360><c> historic</c><00:00:03.919><c> launch</c>
        """

        let cues = parser.parseVTT(vtt)

        #expect(cues.count == 5)
        #expect(cues.map(\.text) == ["Kimi K3", "just", "is", "really a", "historic launch"])
        #expect(zip(cues.compactMap(\.activationTime), [0.2, 0.96, 1.92, 2.28, 3.719])
            .allSatisfy { abs($0 - $1) < 0.0001 })
        #expect(zip(cues.map(\.endTime), [0.96, 1.92, 2.28, 3.719, 4.55])
            .allSatisfy { abs($0 - $1) < 0.0001 })
        #expect(cues.map(\.startTime) == [0, 0.96, 1.92, 2.159, 3.36])
        #expect(!cues.contains { $0.endTime - $0.startTime <= 0.05 })
    }

    @Test("Deterministic spoken roll-up fixture covers several minutes without gaps or duplicates")
    func multiMinuteSpokenRollupFixture() {
        var blocks = ["WEBVTT", "Kind: captions", "Language: en", ""]
        for index in 0..<24 {
            let start = Double(index * 10)
            let end = start + 9.99
            blocks.append("\(vttTime(start)) --> \(vttTime(end)) align:start position:0%")
            blocks.append(
                "We<\(vttMarker(start + 0.35))><c> discuss</c>" +
                "<\(vttMarker(start + 0.9))><c> a</c>" +
                "<\(vttMarker(start + 1.4))><c> concrete</c>" +
                "<\(vttMarker(start + 2.1))><c> software</c>" +
                "<\(vttMarker(start + 2.8))><c> result</c>"
            )
            blocks.append("")
            blocks.append("\(vttTime(end)) --> \(vttTime(end + 0.01))")
            blocks.append("We discuss a concrete software result")
            blocks.append("")
        }

        let cues = parser.parseVTT(blocks.joined(separator: "\n"))

        #expect(cues.count > 20)
        #expect((cues.last?.endTime ?? 0) >= 239)
        #expect(cues.allSatisfy { !$0.text.localizedCaseInsensitiveContains("music") })
        #expect(Set(cues.map { "\($0.startTime)|\($0.text)" }).count == cues.count)
        #expect(cues.allSatisfy {
            $0.effectiveActivationTime >= $0.startTime
                && $0.effectiveActivationTime <= $0.endTime
                && $0.effectiveActivationTime - $0.startTime <= 0.81
        })
        #expect(zip(cues.dropLast(), cues.dropFirst()).allSatisfy {
            abs($0.endTime - $1.effectiveActivationTime) < 0.0001
        })
    }

    // MARK: - HTML entity decoding

    @Test("HTML entities are decoded in cue text")
    func htmlEntitiesDecoded() {
        let vtt = """
        WEBVTT

        00:00:01.000 --> 00:00:03.000
        A &amp; B &lt;C&gt;
        """
        let cues = parser.parseVTT(vtt)
        #expect(cues.count == 1)
        #expect(cues[0].text == "A & B <C>")
    }

    @Test("&quot; is decoded to double-quote")
    func quotEntityDecoded() {
        let vtt = "WEBVTT\n\n00:00:01.000 --> 00:00:02.000\n&quot;quoted&quot;\n"
        let cues = parser.parseVTT(vtt)
        #expect(cues.first?.text == "\"quoted\"")
    }

    // MARK: - Cue identifier lines

    @Test("Cue identifier line before timestamp is skipped")
    func cueIdentifierLineSkipped() {
        let vtt = """
        WEBVTT

        intro
        00:00:01.000 --> 00:00:03.000
        With identifier
        """
        let cues = parser.parseVTT(vtt)
        #expect(cues.count == 1)
        #expect(cues[0].text == "With identifier")
    }

    // MARK: - Multi-line cue text

    @Test("Multi-line cue payload is joined with newline")
    func multiLineTextJoined() {
        let vtt = """
        WEBVTT

        00:00:01.000 --> 00:00:05.000
        Line one
        Line two
        """
        let cues = parser.parseVTT(vtt)
        #expect(cues.count == 1)
        #expect(cues[0].text.contains("Line one"))
        #expect(cues[0].text.contains("Line two"))
    }

    // MARK: - Cue settings on timestamp line

    @Test("Timestamp line with position settings still parses correctly")
    func timestampWithSettingsParsed() {
        let vtt = """
        WEBVTT

        00:00:01.000 --> 00:00:03.000 align:start size:95%
        With settings
        """
        let cues = parser.parseVTT(vtt)
        #expect(cues.count == 1)
        #expect(cues[0].text == "With settings")
    }

    // MARK: - Timestamp formats

    @Test("HH:MM:SS.mmm timestamp format is parsed")
    func hourTimestampFormat() {
        let vtt = """
        WEBVTT

        01:02:03.000 --> 01:02:05.000
        Hour format
        """
        let cues = parser.parseVTT(vtt)
        #expect(cues.count == 1)
        #expect(cues[0].startTime == 3723.0)
        #expect(cues[0].endTime == 3725.0)
    }

    @Test("Cues are returned sorted by start time")
    func cuesSortedByStartTime() {
        // Feed cues out-of-order to confirm sort
        let vtt = """
        WEBVTT

        00:00:05.000 --> 00:00:06.000
        Third

        00:00:01.000 --> 00:00:02.000
        First

        00:00:03.000 --> 00:00:04.000
        Second
        """
        let cues = parser.parseVTT(vtt)
        #expect(cues.count == 3)
        #expect(cues[0].startTime < cues[1].startTime)
        #expect(cues[1].startTime < cues[2].startTime)
    }

    private func vttTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = time - Double(minutes * 60)
        return String(format: "00:%02d:%06.3f", minutes, seconds)
    }

    private func vttMarker(_ time: TimeInterval) -> String {
        "<\(vttTime(time))>"
    }
}
