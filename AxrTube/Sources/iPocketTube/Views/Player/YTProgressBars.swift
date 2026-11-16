#if os(iOS)
import SwiftUI
import iPocketTubeCore

/// Thin red line along the bottom of the portrait player while controls are
/// hidden, over the cached (blue) or buffered (grey) part.
struct YTThinProgress: View {
    /// Line thickness under the video and in the mini player.
    static let height: CGFloat = 4

    let vm: PlaybackViewModel

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle().fill(.white.opacity(0.35)).frame(height: Self.height)
                YTProgressLayers(vm: vm, width: geo.size.width, height: Self.height)
                Rectangle().fill(YTColor.brandRed)
                    .frame(width: geo.size.width * CGFloat(min(max(vm.currentTime / max(vm.duration, 1), 0), 1)), height: Self.height)
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .allowsHitTesting(false)
    }
}

/// Download state under the red played part: blue for what is saved on disk
/// (plays without network), light grey for the player's in-memory buffer
/// when the stream cache is not in use (live, AirPlay).
struct YTProgressLayers: View {
    static let cacheColor = Color(hex: 0x3EA6FF)

    let vm: PlaybackViewModel
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        // Unknown duration would stretch every range across the bar.
        if vm.duration > 0 {
            let duration = vm.duration
            ZStack(alignment: .leading) {
                ForEach(vm.bufferedTimeRanges, id: \.lowerBound) { range in
                    bar(range, duration: duration, color: .white.opacity(0.75))
                }
                ForEach(vm.cachedTimeRanges, id: \.lowerBound) { range in
                    bar(range, duration: duration, color: Self.cacheColor)
                }
            }
            .frame(width: width, alignment: .leading)
            // Short linear glide between real updates; identity by start so a
            // growing range extends instead of being re-created.
            .animation(.linear(duration: 0.2), value: vm.cachedTimeRanges)
            .animation(.linear(duration: 0.2), value: vm.bufferedTimeRanges)
        }
    }

    private func bar(_ range: ClosedRange<Double>, duration: Double, color: Color) -> some View {
        let start = CGFloat(min(max(range.lowerBound / duration, 0), 1))
        let end = CGFloat(min(max(range.upperBound / duration, 0), 1))
        return Rectangle().fill(color)
            .frame(width: max(width * (end - start), 1), height: height)
            .offset(x: width * start)
    }
}
#endif
