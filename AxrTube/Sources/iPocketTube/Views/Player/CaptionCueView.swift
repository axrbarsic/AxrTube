import SwiftUI

// MARK: - CaptionCueView
//
// Renders the active caption cue over the video.
// Positioned at the bottom of the player just above the progress bar.
// YouTube-style: semi-transparent black pill background, white semibold text.

public struct CaptionCueView: View {
    public let text: String

    public init(text: String) {
        self.text = text
    }

    public var body: some View {
        Text(text)
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.black.opacity(0.78))
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .shadow(color: .black.opacity(0.4), radius: 2, x: 0, y: 1)
            .padding(.horizontal, 24)
            .accessibilityIdentifier("player.captionCue")
    }
}
