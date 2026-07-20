import Foundation
import Testing
@testable import iPocketTubeCore

// MARK: - findTimestamps unit tests
//
// Regression tests for task #203: timestamp links (MM:SS / HH:MM:SS) in video
// descriptions and comments should be tappable and seek the player.
//
// findTimestamps(in:) is the public free function in InnerTubeAPI+TextHelpers.swift
// that detects all timestamp patterns and returns (Range<String.Index>, TimeInterval) pairs.

@Suite("findTimestamps")
struct FindTimestampsTests {

    // MARK: - Basic patterns

    @Test("MM:SS pattern produces correct seconds")
    func testFindTimestampsMMSS() {
        let text = "Watch the intro at 1:23 for context."
        let results = findTimestamps(in: text)
        #expect(results.count == 1)
        #expect(results.first?.seconds == 83)   // 1*60 + 23
        // The matched substring should be "1:23"
        if let range = results.first?.range {
            #expect(String(text[range]) == "1:23")
        }
    }

    @Test("HH:MM:SS pattern produces correct seconds")
    func testFindTimestampsHHMMSS() {
        let text = "Best clip at 01:23:45 in the video."
        let results = findTimestamps(in: text)
        #expect(results.count == 1)
        #expect(results.first?.seconds == 5025)  // 1*3600 + 23*60 + 45
        if let range = results.first?.range {
            #expect(String(text[range]) == "01:23:45")
        }
    }

    @Test("Multiple timestamps all detected in order")
    func testFindTimestampsMultiple() {
        let text = "0:00 Intro | 2:30 Main topic | 10:15 Conclusion"
        let results = findTimestamps(in: text)
        #expect(results.count == 3)
        #expect(results[0].seconds == 0)     // 0:00
        #expect(results[1].seconds == 150)   // 2*60 + 30
        #expect(results[2].seconds == 615)   // 10*60 + 15
    }

    @Test("Plain text with no timestamps returns empty")
    func testFindTimestampsNoMatch() {
        let text = "No timestamps here, just regular text and numbers like 42."
        let results = findTimestamps(in: text)
        #expect(results.isEmpty)
    }

    // MARK: - Edge cases

    @Test("Zero timestamp 0:00 is detected")
    func testFindTimestampsZero() {
        let results = findTimestamps(in: "0:00 Start")
        #expect(results.count == 1)
        #expect(results.first?.seconds == 0)
    }

    @Test("Partial digit sequences are not matched")
    func testFindTimestampsNoPartialMatch() {
        // "12:345" should not match "12:34" (5 would be adjacent)
        let results = findTimestamps(in: "bad: 12:345 ok")
        #expect(results.isEmpty)
    }

    @Test("Mixed MM:SS and HH:MM:SS in same string")
    func testFindTimestampsMixed() {
        let text = "Short clip 0:45, long video 1:02:33"
        let results = findTimestamps(in: text)
        #expect(results.count == 2)
        #expect(results[0].seconds == 45)
        #expect(results[1].seconds == 3600 + 2*60 + 33)
    }
}
