import AUNCoreBridge
import AUNDesign
import AUNPlayer
import SwiftUI

#if os(iOS)
    import StoreKit
#endif

/// Resolved invocation target for the iOS App Clip (`E22-D8`: unauthenticated HLS video/Short playback
/// with optional `?t=` timestamp, zero tracking, Kids-safe guard, and `SKOverlay` full-app install prompt).
public struct ClipInvocation: Equatable, Sendable {
    /// Maximum thinned App Clip payload budget enforced in CI (15 MB per Apple App Clip physical/QR limit).
    public static let maxPayloadBytes = 15 * 1024 * 1024

    public var videoID: String
    public var startSeconds: Int?
    public var language: AppLanguage?

    public init(videoID: String, startSeconds: Int? = nil, language: AppLanguage? = nil) {
        self.videoID = videoID
        self.startSeconds = startSeconds
        self.language = language
    }

    public static func resolve(_ url: URL) -> ClipInvocation? {
        guard let parsed = AppLink.parseInvocation(url), let videoID = parsed.link.videoID else { return nil }
        let lang = parsed.language.flatMap(AppLanguage.init(rawValue:))
        return ClipInvocation(videoID: videoID, startSeconds: parsed.startSeconds, language: lang)
    }

    /// Kids-category videos play without external links or full-app prompts (`Epic 20` / `E22 §9.3`).
    public static func isKidsSafeOnly(_ video: Video) -> Bool {
        video.category == "islamic_kids"
    }
}

/// Lightweight App Clip root view (`net.alummahnow.viewer.clip`, `<= 15 MB` budget).
public struct ViewerClipRootView: View {
    @Environment(\.l10n) private var l10n
    private let core: CoreBridge
    @State private var invocation: ClipInvocation?
    @State private var loadedVideo: Video?
    @State private var failed = false
    @State private var showAppOverlay = false
    @State private var player: PlayerController

    public init(core: CoreBridge, initialURL: URL? = nil) {
        self.core = core
        _invocation = State(initialValue: initialURL.flatMap(ClipInvocation.resolve))
        let catalog = core.catalog
        _player = State(initialValue: PlayerController(subtitleLoader: { url in try await catalog.subtitleText(url: url) }))
    }

    public var body: some View {
        VStack(spacing: FanousScale.spacingLg) {
            if let video = loadedVideo {
                if video.isPlayable {
                    PlayerSurface(controller: player)
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .accessibilityIdentifier("clip-player")
                    PlayerControlsBar(controller: player).padding(.horizontal)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text(video.displayTitle(l10n.language))
                        .fanousFont(.title)
                        .fontWeight(.bold)
                        .foregroundStyle(Fanous.textPrimary)
                        .accessibilityIdentifier("clip-title")
                    if let channelName = video.channelName, !channelName.isEmpty {
                        Text(channelName)
                            .fanousFont(.caption)
                            .foregroundStyle(Fanous.textSecondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)

                if !ClipInvocation.isKidsSafeOnly(video) {
                    Button {
                        showAppOverlay = true
                    } label: {
                        Text(l10n("clip.getFullApp"))
                            .fanousFont(.label)
                            .fontWeight(.semibold)
                            .foregroundStyle(Fanous.onPrimary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(RoundedRectangle(cornerRadius: 12).fill(Fanous.primary))
                    }
                    .padding(.horizontal)
                    .accessibilityIdentifier("clip-get-full-app")
                }
                Spacer(minLength: 0)
            } else if failed {
                Text(l10n("common.error.load"))
                    .fanousFont(.body)
                    .foregroundStyle(Fanous.errorText)
                    .padding()
            } else if invocation != nil {
                ThemeLoader()
            } else {
                Text(l10n("clip.openPrompt"))
                    .fanousFont(.body)
                    .foregroundStyle(Fanous.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding()
            }
        }
        .fanousPage()
        .task(id: invocation) { await loadInvocation() }
        .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
            if let url = activity.webpageURL, let resolved = ClipInvocation.resolve(url) {
                invocation = resolved
            }
        }
        .onOpenURL { url in
            if let resolved = ClipInvocation.resolve(url) {
                invocation = resolved
            }
        }
        #if os(iOS)
            .appStoreOverlay(isPresented: $showAppOverlay) {
                SKOverlay.AppClipConfiguration(position: .bottom)
            }
        #endif
    }

    private func loadInvocation() async {
        guard let invocation else { return }
        failed = false
        do {
            let video = try await core.catalog.video(id: invocation.videoID)
            loadedVideo = video
            if let playURL = video.playURL {
                let tracks = (try? await core.catalog.subtitles(videoID: video.id)) ?? []
                player.load(
                    PlaybackItem(
                        url: playURL,
                        title: video.displayTitle(l10n.language),
                        subtitle: video.channelName,
                        subtitles: tracks
                    )
                )
                if let start = invocation.startSeconds, start >= 1 {
                    player.seek(to: Double(start))
                }
            }
        } catch {
            AUNLog.player.error("App Clip video load failed: \(error)")
            failed = true
        }
    }
}
