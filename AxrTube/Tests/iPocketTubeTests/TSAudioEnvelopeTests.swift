import AVFoundation
import Foundation
import Testing
@testable import iPocketTubeCore

@Suite("Amplitude from cached HLS segments")
struct TSAudioEnvelopeTests {
    /// Optional check against a real YouTube segment: AXR_TS_SAMPLE=/path/0.seg
    @Test func realSegmentWhenProvided() throws {
        guard let path = ProcessInfo.processInfo.environment["AXR_TS_SAMPLE"] else { return }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let values = try #require(TSAudioEnvelope.envelope(of: data))
        print("[ts-sample] bins=\(values.count) max=\(values.max() ?? 0) mean=\(values.reduce(0, +) / Float(max(values.count, 1)))")
        #expect(values.count > 50)
        #expect((values.max() ?? 0) > 0.01)
    }

    /// Encodes 1 s quiet + 1 s loud sine to AAC, packs it as HLS packed audio
    /// (ID3 + ADTS) and checks the envelope follows the loudness.
    @Test func packedAudioEnvelopeFollowsLoudness() throws {
        let rate = 44_100.0
        let pcmFormat = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        let pcm = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: AVAudioFrameCount(rate * 2))!
        pcm.frameLength = pcm.frameCapacity
        for i in 0..<Int(pcm.frameLength) {
            let amplitude: Float = i < Int(rate) ? 0.05 : 0.6
            pcm.floatChannelData![0][i] = amplitude * sin(Float(i) * 2 * .pi * 440 / Float(rate))
        }
        var aacDesc = AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatMPEG4AAC, mFormatFlags: 0,
                                                  mBytesPerPacket: 0, mFramesPerPacket: 1024, mBytesPerFrame: 0,
                                                  mChannelsPerFrame: 1, mBitsPerChannel: 0, mReserved: 0)
        let aacFormat = try #require(AVAudioFormat(streamDescription: &aacDesc))
        let encoder = try #require(AVAudioConverter(from: pcmFormat, to: aacFormat))
        var stream = Data([0x49, 0x44, 0x33, 3, 0, 0, 0, 0, 0, 2, 0, 0]) // ID3 header + 2 bytes body
        var fed = false
        while true {
            let out = AVAudioCompressedBuffer(format: aacFormat, packetCapacity: 16, maximumPacketSize: encoder.maximumOutputPacketSize)
            var error: NSError?
            let status = encoder.convert(to: out, error: &error) { _, inStatus in
                if fed { inStatus.pointee = .endOfStream; return nil }
                fed = true
                inStatus.pointee = .haveData
                return pcm
            }
            for p in 0..<Int(out.packetCount) {
                let d = out.packetDescriptions![p]
                let size = Int(d.mDataByteSize), total = size + 7
                let header: [UInt8] = [0xFF, 0xF1, UInt8((1 << 6) | (4 << 2)), UInt8((1 << 6) | (total >> 11)),
                                       UInt8((total >> 3) & 0xFF), UInt8(((total & 7) << 5) | 0x1F), 0xFC]
                stream.append(contentsOf: header)
                stream.append(Data(bytes: out.data.advanced(by: Int(d.mStartOffset)), count: size))
            }
            if status == .endOfStream || status == .error || out.packetCount == 0 { break }
        }
        let values = try #require(TSAudioEnvelope.envelope(of: stream))
        #expect(values.count >= 90)
        let quiet = values[10..<40].reduce(0, +) / 30
        let loud = values[60..<90].reduce(0, +) / 30
        #expect(loud > quiet * 4)
    }
}
