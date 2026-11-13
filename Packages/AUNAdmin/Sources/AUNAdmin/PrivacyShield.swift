import AUNCoreBridge
import AUNDesign
import Foundation
import Observation
import SwiftUI

#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#endif

/// Watches screen capture (AD8 media rules). macOS blocks capture outright (`sharingType = .none`); iOS cannot block a
/// screenshot, so the app hides everything while the screen is recorded, mirrored or on AirPlay, and after a
/// screenshot re-blurs the open item and audits it.
@MainActor @Observable
public final class CaptureMonitor {
    /// The screen is being recorded, mirrored or sent over AirPlay.
    public private(set) var isCaptured = false
    /// Bumped after every screenshot, so the open item re-blurs.
    public private(set) var screenshots = 0
    /// Audit hook: the review open at the time, if any, is attached by the caller.
    @ObservationIgnored public var onEvent: ((CaptureEvent) -> Void)?
    @ObservationIgnored private var tokens: [NSObjectProtocol] = []

    public init(forcedCapture: Bool = false) {
        isCaptured = forcedCapture
        #if os(iOS)
            if !forcedCapture { isCaptured = Self.anyScreenCaptured() }
            let center = NotificationCenter.default
            tokens.append(
                center.addObserver(forName: UIScreen.capturedDidChangeNotification, object: nil, queue: .main) {
                    [weak self] _ in
                    MainActor.assumeIsolated { self?.captureChanged() }
                })
            tokens.append(
                center.addObserver(forName: UIApplication.userDidTakeScreenshotNotification, object: nil, queue: .main) {
                    [weak self] _ in
                    MainActor.assumeIsolated { self?.screenshotTaken() }
                })
        #endif
    }

    #if os(iOS)
        private static func anyScreenCaptured() -> Bool {
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.contains { $0.screen.isCaptured }
        }

        private func captureChanged() {
            let now = Self.anyScreenCaptured()
            guard now != isCaptured else { return }
            isCaptured = now
            onEvent?(now ? .recordingStarted : .recordingStopped)
        }
    #endif

    /// Also called by UI tests through `-AUNFixtureScreenshot`.
    public func screenshotTaken() {
        screenshots += 1
        onEvent?(.screenshot)
    }
}

/// Hides the window's content from the app switcher, the Dock and screen capture.
struct PrivacyShield: ViewModifier {
    @Environment(\.scenePhase) private var phase
    @Environment(\.l10n) private var l10n
    let monitor: CaptureMonitor
    @State private var minimised = false

    func body(content: Content) -> some View {
        content
            .overlay {
                if coverReason != nil {
                    PrivacyCover(message: coverReason.map { l10n($0) } ?? "")
                }
            }
            #if os(macOS)
                .background { WindowCaptureBlocker(minimised: $minimised) }
            #endif
    }

    /// The L10n key of the cover, or nil when content may show.
    private var coverReason: String? {
        if monitor.isCaptured { return "admin.privacy.captured" }
        #if os(iOS)
            // `.inactive` comes before the OS takes the app-switcher snapshot.
            if phase != .active { return "admin.privacy.hidden" }
        #else
            if minimised { return "admin.privacy.hidden" }
        #endif
        return nil
    }
}

/// A plain cover: the motif and one line, nothing from the app behind it.
struct PrivacyCover: View {
    let message: String

    var body: some View {
        VStack(spacing: FanousScale.spacingLg) {
            FanousMotif(.loader).frame(width: 64, height: 64).accessibilityHidden(true)
            Text(message).fanousFont(.body).foregroundStyle(Fanous.textSecondary).multilineTextAlignment(.center)
        }
        .padding(FanousScale.spacingXl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Fanous.background)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("privacy-cover")
    }
}

extension View {
    /// App-switcher cover, capture cover and, on macOS, windows that screen capture and sharing cannot see.
    public func adminPrivacy(_ monitor: CaptureMonitor) -> some View { modifier(PrivacyShield(monitor: monitor)) }
}

#if os(macOS)
    /// Sets `NSWindow.sharingType = .none` on the window that hosts it, so screenshots, recordings and screen sharing
    /// show the window empty, and covers the content before the window is minimised to the Dock.
    struct WindowCaptureBlocker: NSViewRepresentable {
        @Binding var minimised: Bool

        func makeNSView(context: Context) -> BlockerView {
            let view = BlockerView()
            view.onMiniaturize = { minimised = $0 }
            return view
        }

        func updateNSView(_ view: BlockerView, context: Context) {}

        final class BlockerView: NSView {
            var onMiniaturize: ((Bool) -> Void)?
            private var tokens: [NSObjectProtocol] = []

            override func viewDidMoveToWindow() {
                super.viewDidMoveToWindow()
                for token in tokens { NotificationCenter.default.removeObserver(token) }
                tokens.removeAll()
                guard let window else { return }
                window.sharingType = .none
                let center = NotificationCenter.default
                tokens.append(
                    center.addObserver(forName: NSWindow.willMiniaturizeNotification, object: window, queue: .main) {
                        [weak self] _ in
                        MainActor.assumeIsolated { self?.onMiniaturize?(true) }
                    })
                tokens.append(
                    center.addObserver(forName: NSWindow.didDeminiaturizeNotification, object: window, queue: .main) {
                        [weak self] _ in
                        MainActor.assumeIsolated { self?.onMiniaturize?(false) }
                    })
            }
        }
    }
#endif

#if os(macOS)
    /// Every window of the app, sheets and panels included, is excluded from capture as soon as it appears.
    @MainActor public enum WindowCaptureGuard {
        private static var installed = false

        public static func install() {
            guard !installed else { return }
            installed = true
            let center = NotificationCenter.default
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification, NSWindow.didUpdateNotification] {
                center.addObserver(forName: name, object: nil, queue: .main) { note in
                    nonisolated(unsafe) let window = note.object as? NSWindow
                    MainActor.assumeIsolated { window?.sharingType = .none }
                }
            }
            center.addObserver(forName: NSApplication.didUpdateNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    for window in NSApplication.shared.windows where window.sharingType != .none { window.sharingType = .none }
                }
            }
        }
    }
#endif
