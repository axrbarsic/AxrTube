import Foundation
import Testing
@testable import iPocketTubeCore

@Suite("Audio diagnostic ring buffer")
struct AudioDiagnosticRingBufferTests {
    @Test("Buffer remains bounded and ordered under repeated audio events")
    func boundedAndOrdered() {
        let ring = AudioDiagnosticRingBuffer(capacity: 8)
        for index in 0..<20 {
            ring.append(AudioDiagnosticEvent(
                source: "avplayer",
                event: "interruption.\(index)",
                playerRate: Double(index),
                recoveryGeneration: UInt(index)
            ))
        }

        let events = ring.snapshot()
        #expect(events.count == 8)
        #expect(events.map(\.sequence) == Array(13...20).map(UInt64.init))
        #expect(events.first?.event == "interruption.12")
        #expect(events.last?.event == "interruption.19")
    }

    @Test("URL, query, cookie, and token-shaped fields are never retained")
    func sensitiveFieldsAreRedacted() {
        let ring = AudioDiagnosticRingBuffer(capacity: 4)
        ring.append(AudioDiagnosticEvent(
            source: "https://example.invalid/video?token=secret",
            event: "cookie=value",
            decision: "authorization header",
            errorDomain: "signedURL?signature=private"
        ))

        let event = ring.snapshot()[0]
        #expect(event.source == "<redacted>")
        #expect(event.event == "<redacted>")
        #expect(event.decision == "<redacted>")
        #expect(event.errorDomain == "<redacted>")
    }
}
