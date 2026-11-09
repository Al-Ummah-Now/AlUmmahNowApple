import AUNDesign
import AVKit
import SwiftUI

#if os(iOS) || os(macOS)
    /// The picture in the theme's chrome: an AVPlayerLayer with Picture in Picture, the themed controls over it.
    /// AVKit's own chrome is not used on iPhone, iPad and Mac, so the player looks like the site's.
    public struct PlayerSurface: View {
        let controller: PlayerController

        public init(controller: PlayerController) { self.controller = controller }

        public var body: some View {
            ZStack {
                Color.black
                PlayerLayerBridge(controller: controller)
                PlayerChrome(controller: controller)
            }
        }
    }
#endif

#if os(iOS)
    final class PlayerLayerView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }  // swiftlint:disable:this force_cast
    }

    struct PlayerLayerBridge: UIViewRepresentable {
        let controller: PlayerController

        func makeCoordinator() -> Coordinator { Coordinator(controller: controller) }

        func makeUIView(context: Context) -> PlayerLayerView {
            let view = PlayerLayerView()
            view.playerLayer.player = controller.player
            view.playerLayer.videoGravity = .resizeAspect
            let pip = AVPictureInPictureController(playerLayer: view.playerLayer)
            pip?.canStartPictureInPictureAutomaticallyFromInline = true
            pip?.delegate = context.coordinator
            controller.pictureInPicture = pip
            context.coordinator.attach(view)
            return view
        }

        func updateUIView(_ view: PlayerLayerView, context: Context) {}

        static func dismantleUIView(_ view: PlayerLayerView, coordinator: Coordinator) { coordinator.detach() }

        @MainActor
        final class Coordinator: NSObject, AVPictureInPictureControllerDelegate {
            let controller: PlayerController
            private weak var view: PlayerLayerView?
            private var isInPictureInPicture = false
            private var tokens: [NSObjectProtocol] = []

            init(controller: PlayerController) { self.controller = controller }

            /// iOS pauses a video attached to a layer in the background. Detaching keeps the audio playing.
            func attach(_ view: PlayerLayerView) {
                self.view = view
                let center = NotificationCenter.default
                tokens.append(
                    center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) {
                        [weak self] _ in
                        MainActor.assumeIsolated {
                            guard let self, !self.isInPictureInPicture else { return }
                            self.view?.playerLayer.player = nil
                        }
                    })
                tokens.append(
                    center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) {
                        [weak self] _ in
                        MainActor.assumeIsolated {
                            guard let self else { return }
                            self.view?.playerLayer.player = self.controller.player
                        }
                    })
            }

            func detach() {
                for token in tokens { NotificationCenter.default.removeObserver(token) }
                tokens.removeAll()
            }

            nonisolated func pictureInPictureControllerWillStartPictureInPicture(_ pip: AVPictureInPictureController) {
                MainActor.assumeIsolated { isInPictureInPicture = true }
            }

            nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ pip: AVPictureInPictureController) {
                MainActor.assumeIsolated { isInPictureInPicture = false }
            }
        }
    }
#elseif os(macOS)
    final class PlayerLayerView: NSView {
        let playerLayer = AVPlayerLayer()

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer = playerLayer
            playerLayer.videoGravity = .resizeAspect
        }

        required init?(coder: NSCoder) { nil }
    }

    struct PlayerLayerBridge: NSViewRepresentable {
        let controller: PlayerController

        func makeNSView(context: Context) -> PlayerLayerView {
            let view = PlayerLayerView()
            view.playerLayer.player = controller.player
            controller.pictureInPicture = AVPictureInPictureController(playerLayer: view.playerLayer)
            return view
        }

        func updateNSView(_ view: PlayerLayerView, context: Context) {}
    }
#endif

#if os(tvOS)
    /// tvOS keeps AVKit's player: the Siri Remote's transport bar, with the quality, speed and subtitle menus.
    public struct PlayerSurface: UIViewControllerRepresentable {
        let controller: PlayerController
        @Environment(\.l10n) private var l10n

        public init(controller: PlayerController) { self.controller = controller }

        public func makeUIViewController(context: Context) -> AVPlayerViewController {
            let view = AVPlayerViewController()
            view.player = controller.player
            view.speeds = []
            let overlay = UIHostingController(rootView: SubtitleOverlay(controller: controller))
            overlay.view.backgroundColor = .clear
            overlay.view.isUserInteractionEnabled = false
            if let content = view.contentOverlayView {
                overlay.view.frame = content.bounds
                overlay.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                content.addSubview(overlay.view)
            }
            view.addChild(overlay)
            overlay.didMove(toParent: view)
            return view
        }

        public func updateUIViewController(_ view: AVPlayerViewController, context: Context) {
            view.transportBarCustomMenuItems = TransportMenus.items(controller: controller, l10n: l10n)
        }
    }
#endif
