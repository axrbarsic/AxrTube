#if os(iOS)
import AVFoundation
import iPocketTubeCore
import os

/// Amplitude scope for HLS playback through the stream cache. iOS offers
/// no audio tap for HLS, so this decodes the cached audio segments around
/// the playhead (`TSAudioEnvelope`) and serves the same snapshots the live
/// tap produces, synchronised with the player clock.
final class StreamAudioScope: AudioScopeSource, @unchecked Sendable {
    let identity: AudioScopeRenderIdentity
    private weak var player: AVPlayer?
    private let lock = OSAllocatedUnfairLock(initialState: [Int: TSAudioEnvelope.Signal]())
    private let timeline = OSAllocatedUnfairLock<StreamAudioTimeline?>(initialState: nil)
    private var worker: Task<Void, Never>?

    init(videoID: String, player: AVPlayer) {
        identity = RealtimeAudioScopeRegistry.shared.nextIdentity(videoID: videoID)
        self.player = player
    }

    deinit { worker?.cancel() }

    /// Keeps envelopes ready for the segments around the playhead.
    func start() {
        worker = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                await self?.prepareNearby()
                try? await Task.sleep(for: .milliseconds(400))
            }
        }
    }

    private func prepareNearby() async {
        guard let current = await HLSCachingProxy.shared.audioTimeline(),
              current.video == identity.videoID else { return }
        timeline.withLock { $0 = current }
        let t = await MainActor.run { [weak self] in self?.player?.currentTime().seconds ?? 0 }
        guard let index = current.segment(at: t.isFinite ? t : 0) else { return }
        let wanted = Set((index - 1)...(index + 2)).filter { $0 >= 0 && $0 < current.starts.count }
        let ready = lock.withLock { Set($0.keys) }
        for i in wanted.subtracting(ready).sorted() {
            guard let data = await StreamSegmentCache.shared.segment(
                video: current.video, rendition: current.rendition, index: i
            ), let signal = TSAudioEnvelope.signal(of: data) else { continue }
            lock.withLock { $0[i] = signal }
        }
        lock.withLock { cache in cache = cache.filter { abs($0.key - index) <= 4 } }
    }

    /// Envelope value at absolute time `t`, if decoded.
    private func level(at t: Double, timeline: StreamAudioTimeline, envelopes: [Int: TSAudioEnvelope.Signal]) -> Float? {
        guard let i = timeline.segment(at: t), let values = envelopes[i]?.rms else { return nil }
        let bin = Int((t - timeline.starts[i]) * TSAudioEnvelope.binsPerSecond)
        return bin >= 0 && bin < values.count ? values[bin] : nil
    }

    /// Called on the main thread by the waveform display link.
    func snapshot() -> RealtimeAudioScopeSnapshot? {
        guard let player, let timeline = timeline.withLock({ $0 }) else { return nil }
        let t = player.currentTime().seconds
        guard t.isFinite else { return nil }
        let envelopes = lock.withLock { $0 }
        let window = AudioScopeCadencePolicy.rollingWindow
        let bars = AudioScopeCadencePolicy.barCount
        var samples = [Float](repeating: 0, count: bars)
        var hits = 0
        var peak: Float = 0
        let step = 1 / TSAudioEnvelope.binsPerSecond
        var x = t - 10
        while x <= t {   // gain reference: loudest bin of the last 10 s
            if let v = level(at: x, timeline: timeline, envelopes: envelopes) { peak = max(peak, v) }
            x += step * 4
        }
        let gain = max(peak, 0.02)
        for bar in 0..<bars {
            let from = t - window + window * Double(bar) / Double(bars)
            let to = from + window / Double(bars)
            var value: Float = 0
            var y = from
            while y < to {
                if let v = level(at: y, timeline: timeline, envelopes: envelopes) { value = max(value, v); hits += 1 }
                y += step
            }
            samples[bar] = min(1, value / gain)
        }
        guard hits >= 3 else { return nil }
        return RealtimeAudioScopeSnapshot(
            identity: identity,
            sequence: UInt64(max(0, t) * 60),
            samples: samples,
            waveform: waveform(at: t, timeline: timeline, envelopes: envelopes, gain: gain)
        )
    }

    /// 128 points of the real decoded signal ending at `t`, scaled like the
    /// live tap, for the oscilloscope mode.
    private func waveform(at t: Double, timeline: StreamAudioTimeline,
                          envelopes: [Int: TSAudioEnvelope.Signal], gain: Float) -> [Float] {
        guard let i = timeline.segment(at: t), let signal = envelopes[i], !signal.wave.isEmpty else { return [] }
        let end = min(signal.wave.count, Int((t - timeline.starts[i]) * signal.waveRate))
        let start = end - 128
        guard start >= 0 else { return [] }
        let scale = max(0.02, gain * 3)
        return signal.wave[start..<end].map { min(1, max(-1, $0 / scale)) }
    }
}
#endif
