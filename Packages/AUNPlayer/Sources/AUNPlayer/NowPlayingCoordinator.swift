#if os(iOS) || os(macOS)
    import MediaPlayer

    /// Lock-screen and media-key integration, kept working while the video view is detached in the background.
    @MainActor
    final class NowPlayingCoordinator {
        private weak var controller: PlayerController?
        private var targets: [(MPRemoteCommand, Any)] = []

        init(controller: PlayerController) { self.controller = controller }

        func activate() {
            guard targets.isEmpty else {
                update()
                return
            }
            let center = MPRemoteCommandCenter.shared()
            center.skipForwardCommand.preferredIntervals = [NSNumber(value: PlayerController.skipInterval)]
            center.skipBackwardCommand.preferredIntervals = [NSNumber(value: PlayerController.skipInterval)]
            add(center.playCommand) { $0.play() }
            add(center.pauseCommand) { $0.pause() }
            add(center.togglePlayPauseCommand) { $0.togglePlayback() }
            add(center.skipForwardCommand) { $0.skip(by: PlayerController.skipInterval) }
            add(center.skipBackwardCommand) { $0.skip(by: -PlayerController.skipInterval) }
            update()
        }

        private func add(_ command: MPRemoteCommand, action: @escaping @MainActor (PlayerController) -> Void) {
            let token = command.addTarget { [weak self] _ in
                Task { @MainActor in
                    if let controller = self?.controller { action(controller) }
                }
                return .success
            }
            targets.append((command, token))
        }

        func update() {
            guard let controller, let item = controller.item else { return }
            var info: [String: Any] = [
                MPMediaItemPropertyTitle: item.title,
                MPNowPlayingInfoPropertyElapsedPlaybackTime: controller.currentTime,
                MPMediaItemPropertyPlaybackDuration: controller.duration,
                MPNowPlayingInfoPropertyPlaybackRate: controller.isPlaying ? controller.speed : 0,
            ]
            if let subtitle = item.subtitle { info[MPMediaItemPropertyArtist] = subtitle }
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        }

        func deactivate() {
            for (command, token) in targets { command.removeTarget(token) }
            targets.removeAll()
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        }
    }
#endif
