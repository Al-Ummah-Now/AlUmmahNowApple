import AVKit
import CoreMedia
import Foundation
import SwiftUI

#if os(iOS)
    import StoreKit
#endif

/// Language tag resolved from an App Clip invocation URL (`?lang=en|ar` or `/en/...`, `/ar/...`).
public enum ClipLanguage: String, Equatable, Sendable {
    case en
    case ar
}

/// Minimal public video payload decoded directly in the App Clip (`GET /api/videos/:id`)
/// without linking `AUNCoreBridge` or `AunCore` (`E22-D8`: keeps thinned clip well under 15 MB).
public struct ClipVideo: Equatable, Sendable {
    public var id: String
    public var title: String
    public var titleAr: String?
    public var channelName: String?
    public var category: String?
    public var playURL: URL?

    public init(
        id: String, title: String, titleAr: String? = nil, channelName: String? = nil, category: String? = nil,
        playURL: URL? = nil
    ) {
        self.id = id
        self.title = title
        self.titleAr = titleAr
        self.channelName = channelName
        self.category = category
        self.playURL = playURL
    }

    public func displayTitle(isArabic: Bool) -> String {
        if isArabic, let ar = titleAr, !ar.isEmpty { return ar }
        return title
    }
}

/// Fetches public video playback metadata over `URLSession` (`GET /api/videos/:id`).
public struct ClipVideoLoader: Sendable {
    public var apiBaseURL: URL
    private let session: URLSession

    public init(apiBaseURL: URL, session: URLSession = .shared) {
        self.apiBaseURL = apiBaseURL
        self.session = session
    }

    public static func fromMainBundle(_ bundle: Bundle = .main, session: URLSession = .shared) -> ClipVideoLoader {
        let raw = (bundle.infoDictionary?["AUNAPIBaseURL"] as? String) ?? "https://videos.api.qa.alummahnow.net"
        let url = URL(string: raw) ?? URL(string: "https://videos.api.qa.alummahnow.net")!
        return ClipVideoLoader(apiBaseURL: url, session: session)
    }

    private struct Envelope: Decodable {
        var data: RawVideo?
        var video: RawVideo?
        var id: String?
        var title: String?
        var titleLocalized: [String: String]?
        var channelName: String?
        var category: String?
        var playUrl: String?
        var hlsUrl: String?
    }

    private struct RawVideo: Decodable {
        var id: String
        var title: String?
        var titleLocalized: [String: String]?
        var channelName: String?
        var category: String?
        var playUrl: String?
        var hlsUrl: String?
    }

    public func load(videoID: String) async throws -> ClipVideo {
        let url = apiBaseURL.appending(path: "/api/videos/\(videoID)")
        var req = URLRequest(url: url)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        let env = try JSONDecoder().decode(Envelope.self, from: data)
        if let raw = env.data ?? env.video {
            let play = (raw.playUrl ?? raw.hlsUrl).flatMap(URL.init(string:))
            return ClipVideo(
                id: raw.id, title: raw.title ?? "", titleAr: raw.titleLocalized?["ar"],
                channelName: raw.channelName, category: raw.category, playURL: play)
        }
        let play = (env.playUrl ?? env.hlsUrl).flatMap(URL.init(string:))
        return ClipVideo(
            id: env.id ?? videoID, title: env.title ?? "", titleAr: env.titleLocalized?["ar"],
            channelName: env.channelName, category: env.category, playURL: play)
    }
}

/// Resolved invocation target for the iOS App Clip (`E22-D8`: unauthenticated HLS video/Short playback
/// with optional `?t=` timestamp, zero tracking, Kids-safe guard, and `SKOverlay` full-app install prompt).
public struct ClipInvocation: Equatable, Sendable {
    /// Maximum thinned App Clip payload budget enforced in CI (15 MB per Apple App Clip physical/QR limit).
    public static let maxPayloadBytes = 15 * 1024 * 1024

    private static let allowedHosts: Set<String> = [
        "videos.alummahnow.net", "videos.qa.alummahnow.net",
        "alummahnow.link", "qa.alummahnow.link",
    ]
    private static let shortHosts: Set<String> = ["alummahnow.link", "qa.alummahnow.link"]

    public var videoID: String
    public var startSeconds: Int?
    public var language: ClipLanguage?

    public init(videoID: String, startSeconds: Int? = nil, language: ClipLanguage? = nil) {
        self.videoID = videoID
        self.startSeconds = startSeconds
        self.language = language
    }

    public static func resolve(_ url: URL) -> ClipInvocation? {
        guard url.scheme?.lowercased() == "https",
            let host = url.host(percentEncoded: false)?.lowercased(),
            allowedHosts.contains(host)
        else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let queryLang = items.first(where: { $0.name == "lang" })?.value.flatMap(ClipLanguage.init(rawValue:))
        let start = items.first(where: { $0.name == "t" })?.value.flatMap(Int.init).flatMap { $0 >= 1 ? $0 : nil }

        if shortHosts.contains(host) {
            guard parts.count == 2, ["v", "s"].contains(parts[0]), isSafeID(parts[1]) else { return nil }
            return ClipInvocation(videoID: parts[1], startSeconds: start, language: queryLang)
        }
        var rest = parts[...]
        var pathLang: ClipLanguage?
        if let first = rest.first, let parsed = ClipLanguage(rawValue: first) {
            pathLang = parsed
            rest = rest.dropFirst()
        }
        let segs = Array(rest)
        guard segs.count == 2, ["video", "watch", "shorts"].contains(segs[0]), isSafeID(segs[1]) else { return nil }
        return ClipInvocation(videoID: segs[1], startSeconds: start, language: queryLang ?? pathLang)
    }

    private static func isSafeID(_ raw: String) -> Bool {
        guard !raw.isEmpty, raw.count <= 64 else { return false }
        return raw.unicodeScalars.allSatisfy { scalar in
            CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_"
        }
    }

    /// Kids-category videos play without external links or full-app prompts (`Epic 20` / `E22 §9.3`).
    public static func isKidsSafeOnly(_ video: ClipVideo) -> Bool {
        video.category == "islamic_kids"
    }
}

/// Bilingual App Clip UI strings (`en` / `ar`) kept self-contained so the App Clip links zero Rust FFI.
public struct ClipCopy: Equatable, Sendable {
    public var openPrompt: String
    public var loadError: String
    public var getFullApp: String

    public static func resolve(isArabic: Bool) -> ClipCopy {
        if isArabic {
            return ClipCopy(
                openPrompt: "افتح رابط مرئي مشترك من الأمة الآن للمشاهدة فورًا.",
                loadError: "تعذّر تحميل هذا المرئي.",
                getFullApp: "احصل على التطبيق الكامل"
            )
        }
        return ClipCopy(
            openPrompt: "Open a shared Al Ummah Now video link to watch instantly.",
            loadError: "Could not load this video.",
            getFullApp: "Get the full app"
        )
    }
}

/// Lightweight App Clip root view (`net.alummahnow.viewer.clip`, `<= 15 MB` budget).
public struct ViewerClipRootView: View {
    private static let accentEmerald = Color(red: 0.06, green: 0.47, blue: 0.36)

    @Environment(\.locale) private var locale
    private let loader: ClipVideoLoader
    @State private var invocation: ClipInvocation?
    @State private var loadedVideo: ClipVideo?
    @State private var failed = false
    @State private var showAppOverlay = false
    @State private var avPlayer = AVPlayer()

    public init(loader: ClipVideoLoader = .fromMainBundle(), initialURL: URL? = nil) {
        self.loader = loader
        _invocation = State(initialValue: initialURL.flatMap(ClipInvocation.resolve))
    }

    private var isArabic: Bool {
        if let lang = invocation?.language { return lang == .ar }
        return locale.language.languageCode?.identifier == "ar"
    }

    private var copy: ClipCopy { ClipCopy.resolve(isArabic: isArabic) }

    public var body: some View {
        VStack(spacing: 16) {
            if let video = loadedVideo {
                if video.playURL != nil {
                    VideoPlayer(player: avPlayer)
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .accessibilityIdentifier("clip-player")
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text(video.displayTitle(isArabic: isArabic))
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.primary)
                        .accessibilityIdentifier("clip-title")
                    if let channelName = video.channelName, !channelName.isEmpty {
                        Text(channelName)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)

                if !ClipInvocation.isKidsSafeOnly(video) {
                    Button {
                        showAppOverlay = true
                    } label: {
                        Text(copy.getFullApp)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(RoundedRectangle(cornerRadius: 12).fill(Self.accentEmerald))
                    }
                    .padding(.horizontal)
                    .accessibilityIdentifier("clip-get-full-app")
                }
                Spacer(minLength: 0)
            } else if failed {
                Text(copy.loadError)
                    .font(.body)
                    .foregroundStyle(.red)
                    .padding()
            } else if invocation != nil {
                ProgressView()
                    .padding()
            } else {
                Text(copy.openPrompt)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.layoutDirection, isArabic ? .rightToLeft : .leftToRight)
        .task(id: invocation) { await loadInvocation() }
        .onDisappear { avPlayer.pause() }
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
            let video = try await loader.load(videoID: invocation.videoID)
            loadedVideo = video
            if let playURL = video.playURL {
                let item = AVPlayerItem(url: playURL)
                avPlayer.replaceCurrentItem(with: item)
                if let start = invocation.startSeconds, start >= 1 {
                    await avPlayer.seek(to: CMTime(seconds: Double(start), preferredTimescale: 600))
                }
                avPlayer.play()
            }
        } catch {
            failed = true
        }
    }
}
