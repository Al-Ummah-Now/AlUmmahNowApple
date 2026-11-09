#if os(iOS) || os(macOS)
    import AUNCoreBridge
    import AUNDesign
    import AVKit
    import SwiftUI

    /// The themed player chrome over the picture, built from the theme's player tokens (`player.json`):
    /// bar, scrubber with buffered and played fills, glow and handle, big play, spinner, settings menu,
    /// error panel and time. Geometry follows the web skin (`player-skin.css`).
    public struct PlayerChrome: View {
        @Environment(\.fanous) private var theme
        @Environment(\.l10n) private var l10n
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        let controller: PlayerController
        @State private var menu: PlayerMenu?
        @State private var shown = true
        @State private var hideTask: Task<Void, Never>?

        /// `menu` opens a panel at once, for snapshots of the settings menu.
        public init(controller: PlayerController, menu: PlayerMenu? = nil) {
            self.controller = controller
            _menu = State(initialValue: menu)
        }

        private var barVisible: Bool { controller.hasStarted && (shown || !controller.isPlaying || menu != nil) }

        public var body: some View {
            ZStack {
                HStack(spacing: 0) {
                    tapZone(seek: -PlayerController.skipInterval)
                    tapZone(seek: PlayerController.skipInterval)
                }
                .environment(\.layoutDirection, .leftToRight)
                SubtitleOverlay(controller: controller, lifted: barVisible)
                if controller.phase == .failed {
                    PlayerErrorPanel { controller.retry() }
                } else if !controller.hasStarted {
                    BigPlayButton { controller.play() }
                } else if controller.isBuffering || controller.phase == .loading {
                    PlayerSpinner()
                }
                if controller.phase != .failed {
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        PlayerBar(controller: controller, menu: $menu, interacted: { reveal(toggle: false) })
                            .opacity(barVisible ? 1 : 0)
                            .allowsHitTesting(barVisible)
                    }
                }
                if let open = menu {
                    Color.black.opacity(0.001).onTapGesture { menu = nil }
                    PlayerMenuPanel(controller: controller, menu: open) { menu = $0 }
                        .padding(.bottom, 96)
                        .padding(.horizontal, 12)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .environment(\.layoutDirection, .leftToRight)
                }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: FanousScale.durationStandard), value: barVisible)
            .onChange(of: controller.isPlaying) { _, playing in if playing { scheduleHide() } }
        }

        /// One half of the picture: a tap shows or hides the bar, a double tap seeks 10 seconds that way.
        private func tapZone(seek delta: Double) -> some View {
            Color.clear.contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    guard controller.hasStarted else { return }
                    controller.skip(by: delta)
                    reveal(toggle: false)
                }
                .onTapGesture { reveal(toggle: true) }
                .accessibilityHidden(true)
        }

        private func reveal(toggle: Bool) {
            if toggle && shown && controller.isPlaying && menu == nil {
                shown = false
                return
            }
            shown = true
            scheduleHide()
        }

        private func scheduleHide() {
            hideTask?.cancel()
            hideTask = Task {
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { return }
                if controller.isPlaying && menu == nil { shown = false }
            }
        }
    }

    public enum PlayerMenu: Hashable, Sendable { case settings, quality, speed, captions }

    /// A control: 44pt hit area, the theme's hover and press shape behind the icon only, nothing moves.
    struct PlayerButtonStyle: ButtonStyle {
        @Environment(\.fanous) private var theme

        func makeBody(configuration: Configuration) -> some View {
            let player = theme.player
            let shape: FanousShape = player.shape < 0 ? .circle : .rounded(player.shape)
            configuration.label
                .foregroundStyle(Color(player.icon))
                .frame(width: 44, height: 44)
                .background {
                    if configuration.isPressed {
                        FanousSurface(fills: player.press, shape: shape).frame(width: 38, height: 38).scaleEffect(0.93)
                    }
                }
                .contentShape(Rectangle())
        }
    }

    struct PlayerIconButton: View {
        let icon: PlayerIcon
        let label: String
        let id: String
        let action: () -> Void

        var body: some View {
            Button(action: action) { PlayerIconGlyph(icon) }
                .buttonStyle(PlayerButtonStyle())
                .accessibilityLabel(label)
                .accessibilityIdentifier(id)
        }
    }

    /// The control bar: scrubber row over a row of controls, on the theme's bar material.
    struct PlayerBar: View {
        @Environment(\.fanous) private var theme
        @Environment(\.l10n) private var l10n
        let controller: PlayerController
        @Binding var menu: PlayerMenu?
        let interacted: () -> Void

        var body: some View {
            let player = theme.player
            let pad = player.barPad
            VStack(spacing: 0) {
                PlayerScrubber(controller: controller, interacted: interacted)
                // The full row where it fits; on a phone, skip moves to double-tapping the picture's sides and
                // AirPlay into the settings menu, as on the web's narrow player.
                ViewThatFits(in: .horizontal) {
                    controls(compact: false)
                    controls(compact: true)
                }
            }
            .padding(EdgeInsets(top: max(6, pad.top - 24), leading: pad.start, bottom: pad.bottom, trailing: pad.end))
            .background {
                FanousSurface(
                    fills: player.bar, shadows: player.barEdge,
                    shape: player.barRadius > 0 ? .rounded(player.barRadius) : .rect, blur: player.blur)
            }
            .padding(player.barInset)
            .environment(\.layoutDirection, .leftToRight)
        }

        private var hasCaptions: Bool { !(controller.item?.subtitles.isEmpty ?? true) }

        private func controls(compact: Bool) -> some View {
            HStack(spacing: 0) {
                PlayerIconButton(
                    icon: controller.hasEnded ? .replay : controller.isPlaying ? .pause : .play,
                    label: l10n(controller.isPlaying ? "player.pause" : "player.play"), id: "play-pause"
                ) {
                    controller.togglePlayback()
                    interacted()
                }
                if !compact {
                    PlayerIconButton(icon: .skipBack, label: l10n("player.skipBack"), id: "skip-back") {
                        controller.skip(by: -PlayerController.skipInterval)
                        interacted()
                    }
                    PlayerIconButton(icon: .skipForward, label: l10n("player.skipForward"), id: "skip-forward") {
                        controller.skip(by: PlayerController.skipInterval)
                        interacted()
                    }
                }
                PlayerIconButton(
                    icon: controller.isMuted ? .muted : .volume,
                    label: l10n(controller.isMuted ? "player.unmute" : "player.mute"), id: "mute"
                ) {
                    controller.toggleMute()
                    interacted()
                }
                PlayerTime(controller: controller).padding(.leading, compact ? 4 : 8)
                Spacer(minLength: 4)
                PlayerIconButton(icon: .settings, label: l10n("player.settings"), id: "settings-menu") {
                    menu = menu == nil ? .settings : nil
                }
                if hasCaptions {
                    PlayerIconButton(icon: .captions, label: l10n("player.subtitles"), id: "subtitles-menu") {
                        menu = menu == .captions ? nil : .captions
                    }
                }
                PlayerIconButton(icon: .pictureInPicture, label: l10n("player.pip"), id: "pip") {
                    controller.togglePictureInPicture()
                }
                if !compact {
                    RoutePicker(tint: theme.player.icon, active: theme.player.accent).frame(width: 44, height: 44)
                        .accessibilityIdentifier("airplay")
                }
                PlayerIconButton(
                    icon: controller.isFullscreen ? .exitFullscreen : .fullscreen,
                    label: l10n(controller.isFullscreen ? "player.exitFullscreen" : "player.fullscreen"), id: "fullscreen"
                ) { controller.isFullscreen.toggle() }
            }
        }
    }

    /// `0:03 / 0:26`: current time in the icon colour, divider and duration dimmed, tabular digits.
    struct PlayerTime: View {
        @Environment(\.fanous) private var theme
        @Environment(\.l10n) private var l10n
        let controller: PlayerController

        var body: some View {
            HStack(spacing: 4) {
                Text(DisplayFormat.duration(controller.currentTime, l10n.language)).foregroundStyle(Color(theme.player.icon))
                Text("/").foregroundStyle(Color(theme.player.dim))
                Text(DisplayFormat.duration(controller.duration, l10n.language)).foregroundStyle(Color(theme.player.dim))
            }
            .font(.system(size: 13, weight: .medium).monospacedDigit())
            .lineLimit(1)
            .fixedSize()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                l10n(
                    "player.seekValue", DisplayFormat.duration(controller.currentTime, l10n.language),
                    DisplayFormat.duration(controller.duration, l10n.language)))
        }
    }

    /// The scrubber: track with its inner edge, buffered and played fills, the played glow, chapter marks and a
    /// handle that grows while dragged, with the time tip above it.
    struct PlayerScrubber: View {
        @Environment(\.fanous) private var theme
        @Environment(\.l10n) private var l10n
        let controller: PlayerController
        let interacted: () -> Void
        @State private var dragging: Double?

        var body: some View {
            GeometryReader { proxy in
                let inset: CGFloat = 11
                let width = max(1, proxy.size.width - inset * 2)
                let duration = max(controller.duration, 0.001)
                let progress = min(1, max(0, (dragging ?? controller.currentTime) / duration))
                let buffered = min(1, max(0, controller.bufferedTime / duration))
                let height: CGFloat = dragging == nil ? 12 : 16
                let player = theme.player
                ZStack(alignment: .leading) {
                    FanousSurface(fills: player.track, shadows: player.trackEdge, shape: .capsule)
                        .frame(width: width, height: height)
                    FanousSurface(fills: player.buffered, shape: .capsule).frame(
                        width: max(height, width * buffered), height: height
                    )
                    .opacity(buffered > 0 ? 1 : 0)
                    FanousSurface(fills: player.played, shadows: player.glow, shape: .capsule)
                        .frame(width: max(height, width * progress), height: height)
                    ForEach(controller.item?.chapters.filter { $0.startTime > 0 && $0.startTime < duration } ?? []) { chapter in
                        FanousSurface(fills: player.scrim, shape: .rect).frame(width: 2, height: height)
                            .offset(x: width * min(1, chapter.startTime / duration) - 1)
                    }
                    FanousSurface(fills: player.handle, shadows: player.handleEdge, shape: .circle)
                        .frame(width: 18, height: 18)
                        .scaleEffect(dragging == nil ? 1 : 22 / 18)
                        .offset(x: width * progress - 9)
                    if let dragging {
                        Text(DisplayFormat.duration(dragging, l10n.language))
                            .font(.system(size: 12, weight: .semibold).monospacedDigit())
                            .foregroundStyle(Color(player.tipText))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background { FanousSurface(fills: player.tipBg, shadows: player.tipEdge, shape: .capsule) }
                            .fixedSize()
                            .offset(x: width * progress - 20, y: -26)
                    }
                }
                .padding(.horizontal, inset)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            dragging = min(1, max(0, (value.location.x - inset) / width)) * duration
                            interacted()
                        }
                        .onEnded { _ in
                            if let dragging { controller.seek(to: dragging) }
                            dragging = nil
                        })
            }
            .frame(height: 24)
            .accessibilityElement()
            .accessibilityLabel(l10n("player.seek"))
            .accessibilityValue(DisplayFormat.duration(controller.currentTime, l10n.language))
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: controller.skip(by: PlayerController.skipInterval)
                case .decrement: controller.skip(by: -PlayerController.skipInterval)
                @unknown default: break
                }
            }
            .accessibilityIdentifier("scrubber")
        }
    }

    /// The big play button before playback: 76pt, the theme's big fill, ring and glow, 32pt nudged triangle.
    struct BigPlayButton: View {
        @Environment(\.fanous) private var theme
        @Environment(\.l10n) private var l10n
        let action: () -> Void

        var body: some View {
            Button(action: action) {
                PlayerIconGlyph(.play, size: 32)
                    .foregroundStyle(Color(theme.player.bigIcon))
                    .frame(width: 76, height: 76)
                    .background { FanousSurface(fills: theme.player.big, shadows: theme.player.bigEdge, shape: .circle) }
            }
            .buttonStyle(BigPlayPressStyle())
            .accessibilityLabel(l10n("player.play"))
            .accessibilityIdentifier("big-play")
        }
    }

    private struct BigPlayPressStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label.scaleEffect(configuration.isPressed ? 0.96 : 1)
        }
    }

    /// The buffering ring: the track colour with the theme's spinner arc.
    struct PlayerSpinner: View {
        @Environment(\.fanous) private var theme
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var turning = false

        var body: some View {
            ZStack {
                Circle().stroke(trackColor, lineWidth: 4)
                Circle().trim(from: 0, to: 0.25).stroke(
                    Color(theme.player.spin), style: StrokeStyle(lineWidth: 4, lineCap: .round)
                )
                .rotationEffect(.degrees(turning ? 360 : 0))
            }
            .frame(width: 56, height: 56)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) { turning = true }
            }
            .accessibilityHidden(true)
        }

        private var trackColor: Color {
            if case .solid(let color) = theme.player.track.first { return Color(color) }
            return Color(theme.player.dim).opacity(0.3)
        }
    }

    /// The error panel over the picture: the theme's error wash, the message and a retry pill in the accent.
    struct PlayerErrorPanel: View {
        @Environment(\.fanous) private var theme
        @Environment(\.l10n) private var l10n
        let retry: () -> Void

        var body: some View {
            VStack(spacing: 14) {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 28, weight: .medium))
                    .foregroundStyle(Color(theme.player.accent)).accessibilityHidden(true)
                Text(l10n("player.error")).font(.system(size: 14, weight: .medium)).foregroundStyle(Color(theme.player.icon))
                    .multilineTextAlignment(.center).accessibilityIdentifier("player-error")
                Button(action: retry) {
                    Text(l10n("player.retry")).font(.system(size: 14, weight: .semibold)).foregroundStyle(
                        Color(theme.player.tipText)
                    )
                    .padding(.horizontal, 16).frame(minHeight: 36)
                    .background(Color(theme.player.accent), in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("player-retry")
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background { FanousSurface(fills: theme.player.err, shape: .rect) }
        }
    }

    /// The settings and captions panel: the theme's menu surface and edge, hover and selected rows, accent checks.
    /// Rows follow the page's direction; the panel is placed at the bar's end like the web's.
    struct PlayerMenuPanel: View {
        @Environment(\.fanous) private var theme
        @Environment(\.l10n) private var l10n
        let controller: PlayerController
        let menu: PlayerMenu
        let navigate: (PlayerMenu?) -> Void
        @Environment(\.layoutDirection) private var outer

        var body: some View {
            VStack(alignment: .leading, spacing: 2) {
                switch menu {
                case .settings:
                    row(l10n("player.quality"), value: controller.quality.label(l10n), chevron: true) { navigate(.quality) }
                    row(l10n("player.speed"), value: speedLabel(controller.speed, l10n), chevron: true) { navigate(.speed) }
                    HStack(spacing: 8) {
                        Color.clear.frame(width: 14)
                        Text(verbatim: "AirPlay").foregroundStyle(Color(theme.player.icon))
                        Spacer(minLength: 8)
                        RoutePicker(tint: theme.player.icon, active: theme.player.accent).frame(width: 32, height: 32)
                    }
                    .font(.system(size: 14, weight: .medium))
                    .padding(.horizontal, 10)
                    .frame(height: 40)
                    .accessibilityIdentifier("menu-airplay")
                case .quality:
                    header(l10n("player.quality"))
                    ForEach(controller.qualityOptions, id: \.self) { option in
                        row(option.label(l10n), selected: controller.quality == option) {
                            controller.setQuality(option)
                            navigate(nil)
                        }
                    }
                case .speed:
                    header(l10n("player.speed"))
                    ForEach(PlayerController.speeds, id: \.self) { value in
                        row(speedLabel(value, l10n), selected: controller.speed == value) {
                            controller.setSpeed(value)
                            navigate(nil)
                        }
                    }
                case .captions:
                    header(l10n("player.subtitles"))
                    row(l10n("player.subtitles.off"), selected: controller.selectedSubtitleID == nil) {
                        controller.selectSubtitle(id: nil)
                        navigate(nil)
                    }
                    ForEach(controller.item?.subtitles ?? []) { track in
                        row(track.label, selected: controller.selectedSubtitleID == track.id) {
                            controller.selectSubtitle(id: track.id)
                            navigate(nil)
                        }
                    }
                }
            }
            .padding(6)
            .frame(width: 240)
            .background { FanousSurface(fills: theme.player.menu, shadows: theme.player.menuEdge, shape: .rounded(12)) }
            .environment(\.layoutDirection, l10n.language.isRTL ? .rightToLeft : .leftToRight)
            .accessibilityIdentifier("player-menu")
        }

        private func header(_ title: String) -> some View {
            Button {
                navigate(.settings)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.backward").font(.system(size: 12, weight: .semibold))
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Spacer()
                }
                .foregroundStyle(Color(theme.player.dim))
                .padding(.horizontal, 10)
                .frame(height: 36)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }

        private func row(
            _ title: String, value: String? = nil, selected: Bool = false, chevron: Bool = false, action: @escaping () -> Void
        ) -> some View {
            Button(action: action) {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark").font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color(theme.player.accent)).opacity(selected ? 1 : 0).frame(width: 14)
                        .opacity(chevron ? 0 : 1)
                    Text(title).foregroundStyle(Color(theme.player.icon))
                    Spacer(minLength: 8)
                    if let value { Text(value).foregroundStyle(Color(theme.player.dim)) }
                    if chevron {
                        Image(systemName: "chevron.forward").font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color(theme.player.dim))
                    }
                }
                .font(.system(size: 14, weight: .medium))
                .padding(.horizontal, 10)
                .frame(height: 40)
                .contentShape(Rectangle())
            }
            .buttonStyle(MenuRowStyle(selected: selected))
            .accessibilityAddTraits(selected ? .isSelected : [])
        }
    }

    private struct MenuRowStyle: ButtonStyle {
        @Environment(\.fanous) private var theme
        let selected: Bool

        func makeBody(configuration: Configuration) -> some View {
            configuration.label.background {
                if configuration.isPressed {
                    FanousSurface(fills: theme.player.menuHover, shape: .rounded(8))
                } else if selected {
                    FanousSurface(fills: theme.player.menuSelected, shape: .rounded(8))
                }
            }
        }
    }

    #if os(iOS)
        struct RoutePicker: UIViewRepresentable {
            let tint: FanousRGBA
            let active: FanousRGBA

            func makeUIView(context: Context) -> AVRoutePickerView {
                let view = AVRoutePickerView()
                view.prioritizesVideoDevices = true
                return view
            }

            func updateUIView(_ view: AVRoutePickerView, context: Context) {
                view.tintColor = UIColor(Color(tint))
                view.activeTintColor = UIColor(Color(active))
            }
        }
    #else
        struct RoutePicker: NSViewRepresentable {
            let tint: FanousRGBA
            let active: FanousRGBA

            func makeNSView(context: Context) -> AVRoutePickerView { AVRoutePickerView() }

            func updateNSView(_ view: AVRoutePickerView, context: Context) {
                view.setRoutePickerButtonColor(NSColor(Color(tint)), for: .normal)
                view.setRoutePickerButtonColor(NSColor(Color(active)), for: .active)
            }
        }
    #endif
#endif
