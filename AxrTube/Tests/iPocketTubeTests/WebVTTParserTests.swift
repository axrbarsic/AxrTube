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
        <00:00:01.500>Word <00:00:02.000>by <00:00:02.500>word
        """
        let cues = parser.parseVTT(vtt)
        #expect(cues.count == 1)
        #expect(cues[0].text == "Word by word")
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
}
