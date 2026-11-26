import AUNDesign
import AVKit
import SwiftUI

#if os(iOS)
    import SafariServices
#endif

#if os(iOS) || os(tvOS)
    /// AVKit's player view: gives PiP, AirPlay, fullscreen and system transport controls.
    public struct PlayerSurface: UIViewControllerRepresentable {
        let controller: PlayerController
        let reportTitle: String?
        let reportIdentifier: String
        let onReport: (@MainActor () -> Void)?
        @Environment(\.l10n) private var l10n

        public init(
            controller: PlayerController, reportTitle: String? = nil, reportIdentifier: String = "tv-report-video",
            onReport: (@MainActor () -> Void)? = nil
        ) {
            self.controller = controller
            self.reportTitle = reportTitle
            self.reportIdentifier = reportIdentifier
            self.onReport = onReport
        }

        public func makeCoordinator() -> Coordinator { Coordinator(controller: controller) }

        public func makeUIViewController(context: Context) -> AVPlayerViewController {
            let view = AVPlayerViewController()
            view.player = controller.player
            view.speeds = []
            #if os(iOS)
                view.updatesNowPlayingInfoCenter = false
                view.allowsPictureInPicturePlayback = !controller.isPrivateMedia
                view.canStartPictureInPictureAutomaticallyFromInline = !controller.isPrivateMedia
                view.delegate = context.coordinator
                context.coordinator.attach(view)
            #endif
            #if os(iOS)
                let container = SubtitleTouchView(frame: view.view.bounds)
                container.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                var subtitles = SubtitleOverlay(controller: controller)
                subtitles.creditFrameChanged = { [weak container] in container?.creditFrame = $0 }
                subtitles.openCredit = { [weak view] url in
                    guard let view, view.presentedViewController == nil else { return }
                    let browser = SFSafariViewController(url: url)
                    browser.modalPresentationStyle = .overFullScreen
                    view.present(browser, animated: true)
                }
                installOverlay(subtitles, in: container, on: view)
                view.view.addSubview(container)
            #elseif os(tvOS)
                if let content = view.contentOverlayView {
                    installOverlay(SubtitleOverlay(controller: controller), in: content, on: view)
                }
            #endif
            return view
        }

        private func installOverlay(_ subtitles: SubtitleOverlay, in container: UIView, on playerView: AVPlayerViewController) {
            let overlay = UIHostingController(rootView: subtitles)
            playerView.addChild(overlay)
            overlay.view.backgroundColor = .clear
            #if os(tvOS)
                overlay.view.isUserInteractionEnabled = false
            #endif
            overlay.view.frame = container.bounds
            overlay.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            container.addSubview(overlay.view)
            overlay.didMove(toParent: playerView)
        }

        public static func dismantleUIViewController(_ view: AVPlayerViewController, coordinator: Coordinator) {
            #if os(iOS)
                coordinator.detach()
            #endif
        }

        public func updateUIViewController(_ view: AVPlayerViewController, context: Context) {
            #if os(tvOS)
                view.transportBarCustomMenuItems = TransportMenus.items(
                    controller: controller, l10n: l10n, reportTitle: reportTitle,
                    reportIdentifier: reportIdentifier, onReport: onReport)
            #endif
        }

        @MainActor
        public final class Coordinator: NSObject {
            let controller: PlayerController
            #if os(iOS)
                private weak var view: AVPlayerViewController?
                private var isInPictureInPicture = false
                private var tokens: [NSObjectProtocol] = []
            #endif

            init(controller: PlayerController) { self.controller = controller }

            #if os(iOS)
                /// iOS pauses a video attached to a view in the background. Detaching keeps the audio playing.
                func attach(_ view: AVPlayerViewController) {
                    self.view = view
                    let center = NotificationCenter.default
                    tokens.append(
                        center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) {
                            [weak self] _ in
                            MainActor.assumeIsolated {
                                guard let self, !self.isInPictureInPicture else { return }
                                self.view?.player = nil
                            }
                        })
                    tokens.append(
                        center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) {
                            [weak self] _ in
                            MainActor.assumeIsolated {
                                guard let self else { return }
                                self.view?.player = self.controller.player
                            }
                        })
                }

                func detach() {
                    for token in tokens { NotificationCenter.default.removeObserver(token) }
                    tokens.removeAll()
                }
            #endif
        }
    }

    #if os(iOS)
        /// Keeps AVKit's native hit testing outside the credit button.
        private final class SubtitleTouchView: UIView {
            var creditFrame: CGRect = .null

            override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
                creditFrame.contains(point)
            }
        }

        extension PlayerSurface.Coordinator: AVPlayerViewControllerDelegate {
            nonisolated public func playerViewControllerWillStartPictureInPicture(_ view: AVPlayerViewController) {
                MainActor.assumeIsolated { setPictureInPicture(true) }
            }

            nonisolated public func playerViewControllerDidStopPictureInPicture(_ view: AVPlayerViewController) {
                MainActor.assumeIsolated { setPictureInPicture(false) }
            }

            private func setPictureInPicture(_ active: Bool) { isInPictureInPicture = active }
        }
    #endif
#elseif os(macOS)
    public struct PlayerSurface: View {
        let controller: PlayerController

        public init(controller: PlayerController) { self.controller = controller }

        public var body: some View {
            ZStack {
                PlayerViewBridge(player: controller.player, isPrivate: controller.isPrivateMedia)
                SubtitleOverlay(controller: controller)
            }
        }
    }

    private struct PlayerViewBridge: NSViewRepresentable {
        let player: AVPlayer
        let isPrivate: Bool

        func makeNSView(context: Context) -> AVPlayerView {
            let view = AVPlayerView()
            view.player = player
            view.controlsStyle = .floating
            view.allowsPictureInPicturePlayback = !isPrivate
            // Private media never offers the share menu (save, AirDrop, Messages).
            if isPrivate { view.showsSharingServiceButton = false }
            view.speeds = []
            return view
        }

        func updateNSView(_ view: AVPlayerView, context: Context) {}
    }
#endif
