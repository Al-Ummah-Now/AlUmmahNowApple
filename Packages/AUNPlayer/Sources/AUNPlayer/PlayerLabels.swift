import AUNCoreBridge
import AUNDesign
import AVKit
import SwiftUI

extension PlayerQuality {
    func label(_ l10n: L10n) -> String {
        switch self {
        case .auto: l10n("player.quality.auto")
        case .maximum(let height): "\(height)p"
        }
    }
}

func speedLabel(_ speed: Float, _ l10n: L10n) -> String {
    speed == 1 ? l10n("player.speed.normal") : speed.formatted(.number.locale(l10n.language.locale)) + "×"
}

#if os(tvOS)
    /// The tvOS player's transport bar menus for quality, speed and subtitles.
    @MainActor
    enum TransportMenus {
        static func items(controller: PlayerController, l10n: L10n) -> [UIMenuElement] {
            [
                UIMenu(
                    title: l10n("player.quality"), image: UIImage(systemName: "slider.horizontal.3"),
                    children: controller.qualityOptions.map { option in
                        action(option.label(l10n), on: controller.quality == option) { controller.setQuality(option) }
                    }),
                UIMenu(
                    title: l10n("player.speed"), image: UIImage(systemName: "speedometer"),
                    children: PlayerController.speeds.map { value in
                        action(speedLabel(value, l10n), on: controller.speed == value) { controller.setSpeed(value) }
                    }),
                UIMenu(
                    title: l10n("player.subtitles"), image: UIImage(systemName: "captions.bubble"),
                    children: [
                        action(l10n("player.subtitles.off"), on: controller.selectedSubtitleID == nil) {
                            controller.selectSubtitle(id: nil)
                        }
                    ]
                        + (controller.item?.subtitles ?? []).map { track in
                            action(track.label, on: controller.selectedSubtitleID == track.id) {
                                controller.selectSubtitle(id: track.id)
                            }
                        }),
            ]
        }

        private static func action(_ title: String, on: Bool, handler: @escaping @MainActor () -> Void) -> UIAction {
            UIAction(title: title, state: on ? .on : .off) { _ in
                MainActor.assumeIsolated { handler() }
            }
        }
    }
#endif
