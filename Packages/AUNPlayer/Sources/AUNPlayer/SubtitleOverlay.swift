import AUNDesign
import SwiftUI

/// Draws the current cue over the video. High contrast by design, so fixed colors are intended here.
public struct SubtitleOverlay: View {
    let controller: PlayerController

    public init(controller: PlayerController) { self.controller = controller }

    public var body: some View {
        VStack {
            Spacer()
            if let cue = controller.currentCue {
                Text(cue.text)
                    .font(.callout.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 6))
                    .padding(.bottom, 44)
                    .accessibilityIdentifier("subtitle-cue")
            }
        }
        .padding(.horizontal)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }
}
