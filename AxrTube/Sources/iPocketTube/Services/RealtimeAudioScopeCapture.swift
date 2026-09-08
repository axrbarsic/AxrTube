#if os(iOS)
import AVFoundation
import MediaToolbox
import os
import iPocketTubeCore

struct RealtimeAudioScopeSnapshot: Sendable {
    let identity: AudioScopeRenderIdentity
    let sequence: UInt64
    let samples: [Float]
    let waveform: [Float]
}

private final class WeakAudioScopeContext: @unchecked Sendable {
    weak var value: AudioScopeTapContext?

    init(_ value: AudioScopeTapContext) {
        self.value = value
    }
}

/// Process-wide lookup for the one decoded PCM scope attached to the active
/// AVPlayerItem. The lookup never owns the tap context, so replacing an item
/// also releases its old signal source without a second lifecycle owner.
final class RealtimeAudioScopeRegistry: @unchecked Sendable {
    static let shared = RealtimeAudioScopeRegistry()

    private let lock = NSLock()
    private var nextGeneration: UInt64 = 0
    private var contexts: [String: WeakAudioScopeContext] = [:]

    private init() {}

    func makeContext(videoID: String) -> AudioScopeTapContext {
        lock.lock()
        defer { lock.unlock() }
        nextGeneration &+= 1
        return AudioScopeTapContext(
            identity: AudioScopeRenderIdentity(videoID: videoID, generation: nextGeneration)
        )
    }

    func activate(_ context: AudioScopeTapContext) {
        lock.lock()
        contexts[context.identity.videoID] = WeakAudioScopeContext(context)
        lock.unlock()
    }

    func snapshot(videoID: String) -> RealtimeAudioScopeSnapshot? {
        lock.lock()
        let context = contexts[videoID]?.value
        if context == nil { contexts[videoID] = nil }
        lock.unlock()
        return context?.snapshot()
    }
}

/// Fixed-storage, single-producer signal envelope. The real-time callback never
/// allocates and uses try-lock semantics, so a UI snapshot can at worst drop one
/// visual sample rather than block the audio render thread.
final class AudioScopeTapContext: @unchecked Sendable {
    let identity: AudioScopeRenderIdentity

    private static let capacity = 256
    private var lock = os_unfair_lock_s()
    private var values = Array(repeating: Float.zero, count: capacity)
    private var waveform = Array(repeating: Float.zero, count: 128)
    private var times = Array(repeating: TimeInterval.zero, count: capacity)
    private var writeIndex = 0
    private var storedCount = 0
    private var sequence: UInt64 = 0
    private var sampleRate: Double = 44_100
    private var isFloat = true
    private var isSignedInteger = false
    private var bitsPerChannel: UInt32 = 32
    private var elapsedTime: TimeInterval = 0
    private var gainReference: Float = 0.02
    private var smoothedLevel: Float = 0

    init(identity: AudioScopeRenderIdentity) {
        self.identity = identity
    }

    func prepare(format: AudioStreamBasicDescription) {
        sampleRate = max(1, format.mSampleRate)
        isFloat = format.mFormatFlags & kAudioFormatFlagIsFloat != 0
        isSignedInteger = format.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0
        bitsPerChannel = format.mBitsPerChannel
    }

    func consume(
        bufferList: UnsafeMutablePointer<AudioBufferList>,
        frameCount: UInt32,
        startsNewStream: Bool
    ) {
        guard frameCount > 0 else { return }
        var squareSum: Double = 0
        var peak: Float = 0
        var scalarCount = 0
        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)

        for buffer in buffers {
            guard let data = buffer.mData else { continue }
            if isFloat, bitsPerChannel == 32 {
                let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                let pointer = data.assumingMemoryBound(to: Float.self)
                for index in 0..<count {
                    let amplitude = min(1, abs(pointer[index]))
                    squareSum += Double(amplitude * amplitude)
                    peak = max(peak, amplitude)
                }
                scalarCount += count
            } else if isSignedInteger, bitsPerChannel == 16 {
                let count = Int(buffer.mDataByteSize) / MemoryLayout<Int16>.size
                let pointer = data.assumingMemoryBound(to: Int16.self)
                for index in 0..<count {
                    let amplitude = min(1, abs(Float(pointer[index])) / 32_768)
                    squareSum += Double(amplitude * amplitude)
                    peak = max(peak, amplitude)
                }
                scalarCount += count
            } else if isSignedInteger, bitsPerChannel == 32 {
                let count = Int(buffer.mDataByteSize) / MemoryLayout<Int32>.size
                let pointer = data.assumingMemoryBound(to: Int32.self)
                for index in 0..<count {
                    let amplitude = min(1, abs(Float(pointer[index])) / 2_147_483_648)
                    squareSum += Double(amplitude * amplitude)
                    peak = max(peak, amplitude)
                }
                scalarCount += count
            }
        }

        guard scalarCount > 0 else { return }
        let rms = Float(sqrt(squareSum / Double(scalarCount)))
        let rawLevel = rms * 0.78 + peak * 0.22
        let output: Float
        if rawLevel <= LiveAudioScopePolicy.silenceFloor {
            smoothedLevel *= 0.68
            output = smoothedLevel < 0.012 ? 0 : smoothedLevel
        } else {
            let referenceCoefficient: Float = rawLevel >= gainReference ? 0.18 : 0.012
            gainReference += (rawLevel - gainReference) * referenceCoefficient
            let scaled = min(1, rawLevel / max(0.008, gainReference * 1.35))
            let target = Float(log1p(Double(scaled * 24)) / log1p(24))
            let smoothing: Float = target >= smoothedLevel ? 0.58 : 0.20
            smoothedLevel += (target - smoothedLevel) * smoothing
            output = min(max(smoothedLevel, 0), 1)
        }

        elapsedTime += Double(frameCount) / sampleRate
        guard os_unfair_lock_trylock(&lock) else { return }
        // Capture signed PCM from the latest audio buffer, not a synthetic wave.
        if let buffer = buffers.first, let data = buffer.mData {
            let scalarSize = Int(bitsPerChannel / 8)
            let count = scalarSize > 0 ? Int(buffer.mDataByteSize) / scalarSize : 0
            for point in waveform.indices {
                let index = count > 0 ? min(count - 1, point * count / waveform.count) : 0
                var value: Float = 0
                if count > 0, isFloat, bitsPerChannel == 32 {
                    value = data.assumingMemoryBound(to: Float.self)[index]
                } else if count > 0, isSignedInteger, bitsPerChannel == 16 {
                    value = Float(data.assumingMemoryBound(to: Int16.self)[index]) / 32_768
                } else if count > 0, isSignedInteger, bitsPerChannel == 32 {
                    value = Float(data.assumingMemoryBound(to: Int32.self)[index]) / 2_147_483_648
                }
                waveform[point] = value.isFinite ? min(1, max(-1, value / max(0.02, gainReference * 3))) : 0
            }
        }
        if startsNewStream {
            writeIndex = 0
            storedCount = 0
        }
        values[writeIndex] = output
        times[writeIndex] = elapsedTime
        writeIndex = (writeIndex + 1) % Self.capacity
        storedCount = min(Self.capacity, storedCount + 1)
        sequence &+= 1
        os_unfair_lock_unlock(&lock)
    }

    func snapshot() -> RealtimeAudioScopeSnapshot? {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        guard storedCount >= 3 else { return nil }
        let latestIndex = (writeIndex - 1 + Self.capacity) % Self.capacity
        let latestTime = times[latestIndex]
        let windowStart = max(0, latestTime - AudioScopeCadencePolicy.rollingWindow)
        var bars = Array(repeating: Float.zero, count: AudioScopeCadencePolicy.barCount)
        var hits = Array(repeating: 0, count: AudioScopeCadencePolicy.barCount)
        let oldestIndex = (writeIndex - storedCount + Self.capacity) % Self.capacity

        for offset in 0..<storedCount {
            let index = (oldestIndex + offset) % Self.capacity
            guard times[index] >= windowStart else { continue }
            let position = min(
                1,
                max(0, (times[index] - windowStart) / AudioScopeCadencePolicy.rollingWindow)
            )
            let bar = min(
                AudioScopeCadencePolicy.barCount - 1,
                Int(position * Double(AudioScopeCadencePolicy.barCount - 1))
            )
            bars[bar] = max(bars[bar], values[index])
            hits[bar] += 1
        }

        guard hits.reduce(0, +) >= 3 else { return nil }
        var last: Float = 0
        for index in bars.indices {
            if hits[index] == 0 {
                bars[index] = last * 0.88
            } else {
                last = bars[index]
            }
        }
        return RealtimeAudioScopeSnapshot(
            identity: identity,
            sequence: sequence,
            samples: bars,
            waveform: waveform
        )
    }
}

struct RealtimeAudioScopeAttachment {
    let mix: AVAudioMix
    let context: AudioScopeTapContext
}

// MTAudioProcessingTap invokes these callbacks on CoreMedia-owned queues. Keep
// them outside the @MainActor attachment factory so Swift 6 does not inherit
// main-actor isolation for the C function pointers and trap at runtime.
private nonisolated func audioScopeTapInitialize(
    _ tap: MTAudioProcessingTap,
    _ clientInfo: UnsafeMutableRawPointer?,
    _ storageOut: UnsafeMutablePointer<UnsafeMutableRawPointer?>
) {
    storageOut.pointee = clientInfo
}

private nonisolated func audioScopeTapFinalize(_ tap: MTAudioProcessingTap) {
    let storage = MTAudioProcessingTapGetStorage(tap)
    Unmanaged<AudioScopeTapContext>.fromOpaque(storage).release()
}

private nonisolated func audioScopeTapPrepare(
    _ tap: MTAudioProcessingTap,
    _ maximumFrames: CMItemCount,
    _ format: UnsafePointer<AudioStreamBasicDescription>
) {
    let storage = MTAudioProcessingTapGetStorage(tap)
    Unmanaged<AudioScopeTapContext>.fromOpaque(storage)
        .takeUnretainedValue()
        .prepare(format: format.pointee)
}

private nonisolated func audioScopeTapProcess(
    _ tap: MTAudioProcessingTap,
    _ frameCount: CMItemCount,
    _ flags: MTAudioProcessingTapFlags,
    _ bufferList: UnsafeMutablePointer<AudioBufferList>,
    _ framesOut: UnsafeMutablePointer<CMItemCount>,
    _ flagsOut: UnsafeMutablePointer<MTAudioProcessingTapFlags>
) {
    var timeRange = CMTimeRange.invalid
    let status = MTAudioProcessingTapGetSourceAudio(
        tap,
        frameCount,
        bufferList,
        flagsOut,
        &timeRange,
        framesOut
    )
    guard status == noErr else {
        framesOut.pointee = 0
        return
    }
    let storage = MTAudioProcessingTapGetStorage(tap)
    Unmanaged<AudioScopeTapContext>.fromOpaque(storage)
        .takeUnretainedValue()
        .consume(
            bufferList: bufferList,
            frameCount: UInt32(framesOut.pointee),
            startsNewStream: flags & MTAudioProcessingTapFlags(kMTAudioProcessingTapFlag_StartOfStream) != 0
        )
}

enum RealtimeAudioScopeCapture {
    @MainActor
    static func makeAttachment(on item: AVPlayerItem, videoID: String) async throws -> RealtimeAudioScopeAttachment {
        guard let track = try await item.asset.loadTracks(withMediaType: .audio).first else {
            throw NSError(domain: "iPocketTubeAudioScope", code: 1)
        }
        let context = RealtimeAudioScopeRegistry.shared.makeContext(videoID: videoID)
        let retainedContext = Unmanaged.passRetained(context)
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: retainedContext.toOpaque(),
            init: audioScopeTapInitialize,
            finalize: audioScopeTapFinalize,
            prepare: audioScopeTapPrepare,
            unprepare: nil,
            process: audioScopeTapProcess
        )
        var tap: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(
            kCFAllocatorDefault,
            &callbacks,
            kMTAudioProcessingTapCreationFlag_PostEffects,
            &tap
        )
        guard status == noErr, let tap else {
            retainedContext.release()
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        let parameters = AVMutableAudioMixInputParameters(track: track)
        parameters.audioTapProcessor = tap
        let mix = AVMutableAudioMix()
        mix.inputParameters = [parameters]
        return RealtimeAudioScopeAttachment(mix: mix, context: context)
    }
}
#endif
