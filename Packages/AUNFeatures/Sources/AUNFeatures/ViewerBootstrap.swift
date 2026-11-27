import AUNCoreBridge
import Foundation

public enum ViewerBootstrap {
    /// `-AUNUseFixtures YES` selects hermetic data for UI tests; `-AUNFixturePlayable YES` makes its videos play a
    /// bundled clip (store screenshots), `-AUNFixtureLive YES` puts live streams on air.
    public static func makeCore(
        defaults: UserDefaults = .standard, info: [String: Any]? = Bundle.main.infoDictionary,
        telemetry: any TelemetryServicing = NullTelemetryService.shared
    ) -> CoreBridge {
        if defaults.bool(forKey: "AUNUseFixtures") {
            return .fixtures(
                playable: defaults.bool(forKey: "AUNFixturePlayable"), live: defaults.bool(forKey: "AUNFixtureLive"),
                language: AppLanguage(rawValue: defaults.string(forKey: "AUNLanguage") ?? "") ?? .en)
        }
        var bridge = CoreBridge.temporaryNative(environment: .fromInfoDictionary(info))
        bridge.telemetry = telemetry
        return bridge
    }
}

/// A screen the viewer can open.
public enum ViewerDestination: Hashable, Codable, Sendable {
    case video(String)
    case live(String)
    /// Every stream on air and coming.
    case liveList

    /// Opened at launch, for UI automation.
    public static func launch(_ defaults: UserDefaults = .standard) -> ViewerDestination? {
        if let id = defaults.string(forKey: "AUNOpenLive") { return .live(id) }
        return defaults.string(forKey: "AUNOpenVideo").map { .video($0) }
    }
}

/// Universal links the viewer opens (videos host, `/{en,ar}/video/…`, `/shorts/…`, `/live/…`; AppLink). Videos and Shorts
/// open their watch page, live streams and premieres theirs; playlists, posts and channels have no screen in this app yet, so the app opens on Home.
public enum ViewerLinks {
    public static func destination(for url: URL) -> ViewerDestination? {
        guard let link = AppLink.parse(url) else { return nil }
        if case .live(let id) = link { return .live(id) }
        if let id = link.videoID { return .video(id) }
        AUNLog.network.info("Universal link without a viewer screen, opening Home")
        return nil
    }
}
