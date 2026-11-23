import AUNCoreBridge
import AUNDesign
import AVKit
import SwiftUI

extension PlayerQuality {
    func label(_ l10n: L10n) -> String {
        switch self {
        case .auto: l10n("player.quality.auto")
        case .maximum(let height): DisplayFormat.number(height, l10n.language, grouping: false) + "p"
        }
    }
}

func speedLabel(_ speed: Float, _ l10n: L10n) -> String {
    speed == 1 ? l10n("player.speed.normal") : DisplayFormat.number(Double(speed), l10n.language) + "×"
}

#if os(iOS) || os(macOS)
    /// The scrubber with the elapsed and total time, then skip, quality, speed, subtitles and AirPlay. HStack order
    /// mirrors automatically in RTL, the scrubber filling from the right.
    public struct PlayerControlsBar: View {
        @Environment(\.l10n) private var l10n
        let controller: PlayerController
        /// The video's length from the catalog, the same as its card shows; the asset's own length when it has none.
        let knownDuration: Double?

        public init(controller: PlayerController, knownDuration: Double? = nil) {
            self.controller = controller
            self.knownDuration = knownDuration
        }

        private var skipSeconds: String { DisplayFormat.number(Int(PlayerController.skipInterval), l10n.language) }

        public var body: some View {
            VStack(spacing: FanousScale.spacingXs) {
                PlayerTimeline(controller: controller, knownDuration: knownDuration)
                buttons
            }
        }

        private var buttons: some View {
            HStack(spacing: 16) {
                Button {
                    controller.skip(by: -PlayerController.skipInterval)
                } label: {
                    Image(systemName: "gobackward.10")
                }
                .accessibilityLabel(l10n("player.skipBack", skipSeconds))
                .accessibilityIdentifier("skip-back")
                Button {
                    controller.skip(by: PlayerController.skipInterval)
                } label: {
                    Image(systemName: "goforward.10")
                }
                .accessibilityLabel(l10n("player.skipForward", skipSeconds))
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

    /// The scrubber and «elapsed / total», «٠:٠٠ / ٢٧:٢٢» paused at the start.
    struct PlayerTimeline: View {
        @Environment(\.l10n) private var l10n
        let controller: PlayerController
        let knownDuration: Double?

        /// The catalog length, so the page and the video's card agree; else the asset's, once it has loaded.
        private var total: Double { knownDuration.flatMap { $0 > 0 ? $0 : nil } ?? controller.duration }

        var body: some View {
            HStack(spacing: FanousScale.spacingMd) {
                PlayerScrubber(
                    value: min(controller.currentTime, total), total: max(total, 1), enabled: total > 0,
                    seek: { controller.seek(to: $0) }
                )
                .accessibilityLabel(l10n("player.position"))
                .accessibilityValue(time)
                .accessibilityIdentifier("player-scrubber")
                Text(time)
                    .fanousFont(.caption)
                    .monospacedDigit()
                    .foregroundStyle(Fanous.textSecondary)
                    .fixedSize()
                    .accessibilityIdentifier("player-time")
            }
        }

        private var time: String {
            l10n(
                "player.time", DisplayFormat.duration(controller.currentTime, l10n.language),
                DisplayFormat.duration(total, l10n.language))
        }
    }

    /// The position track, drawn in Fanous parts so it reads on every page: the rest of the track in `outline` and the
    /// played part and the thumb in `link`, the theme's strongest accent on its background (the system slider's grey
    /// track and gold fill nearly vanished on the light themes' cream). It fills from the leading edge, so from the
    /// right in RTL; VoiceOver gets the system slider, so it adjusts like any other.
    struct PlayerScrubber: View {
        @Environment(\.layoutDirection) private var direction
        let value: Double
        let total: Double
        let enabled: Bool
        let seek: (Double) -> Void

        private static let track: CGFloat = 4
        private static let thumb: CGFloat = 14
        /// The whole control is at least this tall, so the thumb is easy to catch.
        private static let target: CGFloat = 28

        var body: some View {
            GeometryReader { proxy in
                let usable = max(proxy.size.width - Self.thumb, 1)
                let played = usable * CGFloat(min(max(value / total, 0), 1))
                ZStack(alignment: .leading) {
                    Capsule().fill(Fanous.outline).frame(height: Self.track)
                    HStack(spacing: 0) {
                        Capsule().fill(Fanous.link).frame(width: played + Self.thumb / 2, height: Self.track)
                            .padding(.trailing, -Self.thumb / 2)
                        Circle().fill(Fanous.link)
                            .overlay(Circle().strokeBorder(Fanous.background, lineWidth: 2))
                            .frame(width: Self.thumb, height: Self.thumb)
                        Spacer(minLength: 0)
                    }
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0).onChanged { drag in
                        // The gesture reports the physical x; the track runs from the leading edge.
                        let x = direction == .rightToLeft ? proxy.size.width - drag.location.x : drag.location.x
                        let fraction = min(max((x - Self.thumb / 2) / usable, 0), 1)
                        seek(Double(fraction) * total)
                    },
                    including: enabled ? .all : .none)
            }
            .frame(height: Self.target)
            .opacity(enabled ? 1 : 0.5)
            .accessibilityRepresentation {
                Slider(value: Binding(get: { value }, set: seek), in: 0...total).disabled(!enabled)
            }
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
