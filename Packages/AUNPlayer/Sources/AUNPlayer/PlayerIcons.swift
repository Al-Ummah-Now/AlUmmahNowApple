import SwiftUI

/// The player's control icons. Every glyph is centred in its 44pt hit area within ±1px
/// (`PlayerIconAlignmentTests`): by its ink box, or for the play triangle by its area centroid,
/// which the web nudges 7% of the icon width toward the point (docs/design/player-themes.md).
public enum PlayerIcon: String, CaseIterable, Sendable {
    case play, pause, replay, skipBack, skipForward, volume, muted, settings, captions, pictureInPicture, fullscreen,
        exitFullscreen

    var symbol: String {
        switch self {
        case .play: "play.fill"
        case .pause: "pause.fill"
        case .replay: "arrow.counterclockwise"
        case .skipBack: "gobackward.10"
        case .skipForward: "goforward.10"
        case .volume: "speaker.wave.2.fill"
        case .muted: "speaker.slash.fill"
        case .settings: "gearshape"
        case .captions: "captions.bubble"
        case .pictureInPicture: "pip.enter"
        case .fullscreen: "arrow.up.left.and.arrow.down.right"
        case .exitFullscreen: "arrow.down.right.and.arrow.up.left"
        }
    }

    /// Glyph size within the 22pt icon box; wide glyphs are drawn smaller so they stay inside it.
    var scale: CGFloat { self == .pictureInPicture ? 0.74 : 0.86 }

    /// Play triangles read as centred by their mass, not their box.
    public var centresByMass: Bool { self == .play }

    /// Offset that puts the glyph's optical centre on the hit area's centre, as a fraction of the icon size.
    /// SF Symbols draw some glyphs off their image centre (the speaker sits left of its waves' box).
    var nudge: CGSize {
        switch self {
        case .play: CGSize(width: 0.07, height: 0)
        default: .zero
        }
    }
}

/// One glyph at a size, nudged to its optical centre. Media controls stay left to right in Arabic, as on the web.
public struct PlayerIconGlyph: View {
    let icon: PlayerIcon
    let size: CGFloat

    public init(_ icon: PlayerIcon, size: CGFloat = 22) {
        self.icon = icon
        self.size = size
    }

    public var body: some View {
        Image(systemName: icon.symbol)
            .font(.system(size: size * icon.scale, weight: .medium))
            .frame(width: size, height: size)
            .offset(x: icon.nudge.width * size, y: icon.nudge.height * size)
            .environment(\.layoutDirection, .leftToRight)
    }
}
