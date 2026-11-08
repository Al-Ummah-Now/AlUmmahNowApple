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

#if os(iOS) || os(macOS)
    /// Quality, speed, subtitles, skip and AirPlay. HStack order mirrors automatically in RTL.
    public struct PlayerControlsBar: View {
        @Environment(\.l10n) private var l10n
        let controller: PlayerController

        public init(controller: PlayerController) { self.controller = controller }

        public var body: some View {
            HStack(spacing: 16) {
                Button {
                    controller.skip(by: -PlayerController.skipInterval)
                } label: {
                    Image(systemName: "gobackward.10")
                }
                .accessibilityLabel(l10n("player.skipBack"))
                .accessibilityIdentifier("skip-back")
                Button {
                    controller.skip(by: PlayerController.skipInterval)
                } label: {
                    Image(systemName: "goforward.10")
                }
                .accessibilityLabel(l10n("player.skipForward"))
                .accessibilityIdentifier("skip-forward")
                Spacer()
                qualityMenu
                speedMenu
                subtitleMenu
                RoutePicker().frame(width: 28, height: 28)
            }
            .font(.title3)
            .foregroundStyle(Fanous.textPrimary)
            .buttonStyle(.plain)
            #if os(macOS)
                .menuStyle(.borderlessButton)
            #endif
        }

        private var qualityMenu: some View {
            Menu {
                ForEach(controller.qualityOptions, id: \.self) { option in
                    Toggle(
                        option.label(l10n),
                        isOn: Binding(get: { controller.quality == option }, set: { _ in controller.setQuality(option) }))
                }
            } label: {
                Image(systemName: "slider.horizontal.3").accessibilityLabel(l10n("player.quality"))
            }
            .accessibilityIdentifier("quality-menu")
        }

        private var speedMenu: some View {
            Menu {
                ForEach(PlayerController.speeds, id: \.self) { value in
                    Toggle(
                        speedLabel(value, l10n),
                        isOn: Binding(get: { controller.speed == value }, set: { _ in controller.setSpeed(value) }))
                }
            } label: {
                Image(systemName: "speedometer").accessibilityLabel(l10n("player.speed"))
            }
            .accessibilityIdentifier("speed-menu")
        }

        private var subtitleMenu: some View {
            Menu {
                Toggle(
                    l10n("player.subtitles.off"),
                    isOn: Binding(get: { controller.selectedSubtitleID == nil }, set: { _ in controller.selectSubtitle(id: nil) })
                )
                ForEach(controller.item?.subtitles ?? []) { track in
                    Toggle(
                        track.label,
                        isOn: Binding(
                            get: { controller.selectedSubtitleID == track.id },
                            set: { _ in controller.selectSubtitle(id: track.id) }))
                }
            } label: {
                Image(systemName: "captions.bubble").accessibilityLabel(l10n("player.subtitles"))
            }
            .accessibilityIdentifier("subtitles-menu")
        }
    }

    #if os(iOS)
        private struct RoutePicker: UIViewRepresentable {
            func makeUIView(context: Context) -> AVRoutePickerView { AVRoutePickerView() }
            func updateUIView(_ view: AVRoutePickerView, context: Context) {}
        }
    #else
        private struct RoutePicker: NSViewRepresentable {
            func makeNSView(context: Context) -> AVRoutePickerView { AVRoutePickerView() }
            func updateNSView(_ view: AVRoutePickerView, context: Context) {}
        }
    #endif
#endif

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
