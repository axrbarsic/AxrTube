import AVFoundation
import Foundation

/// Loudness envelope of a cached HLS segment, for the downloads amplitude
/// scope. iOS gives no audio tap for HLS playback, but the proxy already has
/// every segment on disk: demux MPEG-TS (or read raw ADTS), decode the AAC
/// and measure RMS in short bins. Offsets are seconds from segment start.
public enum TSAudioEnvelope {
    public static let binsPerSecond = 50.0
    /// Decimation of the mono signal kept for the oscilloscope view.
    public static let waveDecimation = 8

    /// Decoded audio of one segment: loudness bins and a decimated waveform.
    public struct Signal: Sendable {
        /// RMS per bin (0…1), first bin at the segment's first audio sample.
        public var rms: [Float]
        /// Mono samples (-1…1) at `waveRate` Hz.
        public var wave: [Float]
        public var waveRate: Double
    }

    public static func envelope(of segment: Data) -> [Float]? {
        signal(of: segment)?.rms
    }

    public static func signal(of segment: Data) -> Signal? {
        let frames = adtsFrames(in: segment)
        guard let first = frames.first, let header = ADTSHeader(first) else { return nil }
        return decode(frames: frames, header: header)
    }

    // MARK: Container

    /// ADTS frames in order, from MPEG-TS (AAC elementary stream) or raw ADTS.
    static func adtsFrames(in data: Data) -> [Data] {
        let bytes = [UInt8](data)
        if bytes.count >= 188, bytes[0] == 0x47 { return splitADTS(tsAudioPayload(bytes)) }
        return splitADTS(Array(bytes.dropFirst(id3Length(bytes))))
    }

    /// Concatenated PES payloads of the first AAC stream in the transport stream.
    static func tsAudioPayload(_ b: [UInt8]) -> [UInt8] {
        var pmtPID: Int?
        var audioPID: Int?
        var out: [UInt8] = []
        var offset = 0
        while offset + 188 <= b.count {
            defer { offset += 188 }
            guard b[offset] == 0x47 else { continue }
            let start = b[offset + 1] & 0x40 != 0
            let pid = Int(b[offset + 1] & 0x1F) << 8 | Int(b[offset + 2])
            let afc = (b[offset + 3] >> 4) & 0x3
            var p = offset + 4
            if afc == 2 || afc == 3 { p += 1 + Int(b[offset + 4]) }
            guard afc == 1 || afc == 3, p < offset + 188 else { continue }
            let payload = Array(b[p..<(offset + 188)])
            if pid == 0, start, pmtPID == nil {
                pmtPID = parsePAT(payload)
            } else if pid == pmtPID, start, audioPID == nil {
                audioPID = parsePMT(payload)
            } else if pid == audioPID {
                if start {
                    // PES header: 00 00 01 id len(2) flags(2) hdrlen
                    guard payload.count > 9, payload[0] == 0, payload[1] == 0, payload[2] == 1 else { continue }
                    let body = 9 + Int(payload[8])
                    if body < payload.count { out += payload[body...] }
                } else {
                    out += payload
                }
            }
        }
        return out
    }

    private static func parsePAT(_ p: [UInt8]) -> Int? {
        guard let s = sectionStart(p), s + 8 < p.count else { return nil }
        let length = Int(p[s + 1] & 0x0F) << 8 | Int(p[s + 2])
        var i = s + 8
        while i + 4 <= min(p.count, s + 3 + length - 4) {
            let program = Int(p[i]) << 8 | Int(p[i + 1])
            let pid = Int(p[i + 2] & 0x1F) << 8 | Int(p[i + 3])
            if program != 0 { return pid }
            i += 4
        }
        return nil
    }

    private static func parsePMT(_ p: [UInt8]) -> Int? {
        guard let s = sectionStart(p), s + 12 < p.count else { return nil }
        let length = Int(p[s + 1] & 0x0F) << 8 | Int(p[s + 2])
        let infoLength = Int(p[s + 10] & 0x0F) << 8 | Int(p[s + 11])
        var i = s + 12 + infoLength
        let end = min(p.count, s + 3 + length - 4)
        while i + 5 <= end {
            let type = p[i]
            let pid = Int(p[i + 1] & 0x1F) << 8 | Int(p[i + 2])
            let esLength = Int(p[i + 3] & 0x0F) << 8 | Int(p[i + 4])
            if type == 0x0F { return pid }   // ISO/IEC 13818-7 ADTS AAC
            i += 5 + esLength
        }
        return nil
    }

    private static func sectionStart(_ p: [UInt8]) -> Int? {
        guard let pointer = p.first else { return nil }
        let s = 1 + Int(pointer)
        return s < p.count ? s : nil
    }

    /// Packed audio (HLS .aac) starts with an ID3 timestamp tag.
    static func id3Length(_ b: [UInt8]) -> Int {
        guard b.count >= 10, b[0] == 0x49, b[1] == 0x44, b[2] == 0x33 else { return 0 }
        let size = Int(b[6] & 0x7F) << 21 | Int(b[7] & 0x7F) << 14 | Int(b[8] & 0x7F) << 7 | Int(b[9] & 0x7F)
        return min(b.count, 10 + size + (b[5] & 0x10 != 0 ? 10 : 0))
    }

    static func splitADTS(_ b: [UInt8]) -> [Data] {
        var frames: [Data] = []
        var i = 0
        while i + 7 <= b.count {
            guard b[i] == 0xFF, b[i + 1] & 0xF0 == 0xF0 else { i += 1; continue }
            let length = Int(b[i + 3] & 0x03) << 11 | Int(b[i + 4]) << 3 | Int(b[i + 5] >> 5)
            guard length >= 7, i + length <= b.count else { break }
            frames.append(Data(b[i..<(i + length)]))
            i += length
        }
        return frames
    }

    // MARK: Decoding

    struct ADTSHeader {
        static let rates: [Double] = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350]
        var sampleRate: Double
        var channels: UInt32
        var headerLength: Int

        init?(_ frame: Data) {
            let b = [UInt8](frame.prefix(9))
            guard b.count >= 7 else { return nil }
            let rateIndex = Int((b[2] >> 2) & 0x0F)
            guard rateIndex < Self.rates.count else { return nil }
            sampleRate = Self.rates[rateIndex]
            channels = UInt32((b[2] & 0x01) << 2 | (b[3] >> 6))
            headerLength = b[1] & 0x01 == 1 ? 7 : 9
            if channels == 0 { channels = 2 }
        }
    }

    private static func decode(frames: [Data], header: ADTSHeader) -> Signal? {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: header.sampleRate, mFormatID: kAudioFormatMPEG4AAC, mFormatFlags: 0,
            mBytesPerPacket: 0, mFramesPerPacket: 1024, mBytesPerFrame: 0,
            mChannelsPerFrame: header.channels, mBitsPerChannel: 0, mReserved: 0
        )
        guard let input = AVAudioFormat(streamDescription: &asbd),
              let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: header.sampleRate,
                                         channels: header.channels, interleaved: false),
              let converter = AVAudioConverter(from: input, to: output) else { return nil }
        let packets = frames.map { $0.dropFirst(header.headerLength) }
        let maxSize = packets.map(\.count).max() ?? 0
        let compressed = AVAudioCompressedBuffer(format: input, packetCapacity: AVAudioPacketCount(packets.count),
                                                 maximumPacketSize: max(maxSize, 1))
        var cursor = 0
        for (index, packet) in packets.enumerated() {
            packet.withUnsafeBytes { raw in
                compressed.data.advanced(by: cursor).copyMemory(from: raw.baseAddress!, byteCount: packet.count)
            }
            compressed.packetDescriptions?[index] = AudioStreamPacketDescription(
                mStartOffset: Int64(cursor), mVariableFramesInPacket: 0, mDataByteSize: UInt32(packet.count)
            )
            cursor += packet.count
        }
        compressed.packetCount = AVAudioPacketCount(packets.count)
        compressed.byteLength = UInt32(cursor)

        guard let pcm = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: AVAudioFrameCount(packets.count * 1024 + 2048)) else { return nil }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: pcm, error: &error) { _, outStatus in
            if supplied { outStatus.pointee = .endOfStream; return nil }
            supplied = true
            outStatus.pointee = .haveData
            return compressed
        }
        guard status != .error, let channels = pcm.floatChannelData, pcm.frameLength > 0 else { return nil }
        let bin = max(1, Int(header.sampleRate / binsPerSecond))
        let count = Int(pcm.frameLength)
        var values: [Float] = []
        values.reserveCapacity(count / bin + 1)
        var start = 0
        while start < count {
            let end = min(count, start + bin)
            var sum: Float = 0
            for c in 0..<Int(output.channelCount) {
                let samples = channels[c]
                for i in start..<end { sum += samples[i] * samples[i] }
            }
            values.append(min(1, (sum / Float((end - start) * Int(output.channelCount))).squareRoot()))
            start = end
        }
        var wave: [Float] = []
        wave.reserveCapacity(count / waveDecimation + 1)
        let channelCount = Int(output.channelCount)
        for i in stride(from: 0, to: count, by: waveDecimation) {
            var mono: Float = 0
            for c in 0..<channelCount { mono += channels[c][i] }
            wave.append(mono / Float(channelCount))
        }
        return Signal(rms: values, wave: wave, waveRate: header.sampleRate / Double(waveDecimation))
    }
}
