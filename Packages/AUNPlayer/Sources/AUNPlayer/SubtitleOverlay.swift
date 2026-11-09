import AUNDesign
import SwiftUI

/// Draws the current cue over the video on the theme's cue fill, above the bar while it shows.
public struct SubtitleOverlay: View {
    @Environment(\.fanous) private var theme
    let controller: PlayerController
    let lifted: Bool

    public init(controller: PlayerController, lifted: Bool = false) {
        self.controller = controller
        self.lifted = lifted
    }

    public var body: some View {
        VStack {
            Spacer()
            if let cue = controller.currentCue {
                Text(cue.text)
                    .font(.callout.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Color(theme.player.icon))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background { FanousSurface(fills: theme.player.cue, shape: .rounded(4)) }
                    .padding(.bottom, lifted ? 88 : 16)
                    .accessibilityIdentifier("subtitle-cue")
            }
        }
        .padding(.horizontal)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
        .animation(.easeOut(duration: FanousScale.durationStandard), value: lifted)
    }
}
