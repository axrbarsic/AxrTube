import Testing
@testable import SmartTubeIOSCore

@Suite("EDR press pulse envelope")
struct SmartTubePressPulseEnvelopeTests {
    @Test("Pulse heats immediately and cools without rebound")
    func heatAndCooling() {
        #expect(SmartTubePressPulseEnvelope.heat(elapsed: 0) == 0)
        #expect(SmartTubePressPulseEnvelope.heat(elapsed: 0.03) > 0)
        #expect(SmartTubePressPulseEnvelope.heat(elapsed: 0.08) == 1)
        let samples = stride(from: 0.105, through: 0.825, by: 0.02)
            .map { SmartTubePressPulseEnvelope.heat(elapsed: $0) }
        for pair in zip(samples, samples.dropFirst()) {
            #expect(pair.1 <= pair.0)
        }
        #expect(SmartTubePressPulseEnvelope.heat(elapsed: 0.826) == 0)
    }

    @Test("Reduce Motion keeps a visible but bounded pulse")
    func reduceMotion() {
        #expect(SmartTubePressPulseEnvelope.heat(elapsed: 0.05, reduceMotion: true) == 0.58)
        #expect(SmartTubePressPulseEnvelope.heat(elapsed: 0.5, reduceMotion: true) == 0)
    }
}
