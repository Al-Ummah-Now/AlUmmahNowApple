import AUNCoreBridge
import Foundation

public enum ViewerBootstrap {
    /// `-AUNUseFixtures YES` selects hermetic data for UI tests; `-AUNFixturePlayable YES` makes its videos play a
    /// bundled clip (store screenshots).
    public static func makeCore(defaults: UserDefaults = .standard, info: [String: Any]? = Bundle.main.infoDictionary)
        -> CoreBridge
    {
        if defaults.bool(forKey: "AUNUseFixtures") { return .fixtures(playable: defaults.bool(forKey: "AUNFixturePlayable")) }
        return .temporaryNative(environment: .fromInfoDictionary(info))
    }
}

/// Universal links the viewer opens (videos host, `/{en,ar}/video/…`, `/shorts/…`; AppLink). Videos and Shorts open
/// their watch page; playlists, posts and channels have no screen in this app yet, so the app opens on Home.
public enum ViewerLinks {
    public static func videoID(for url: URL) -> String? {
        guard let link = AppLink.parse(url) else { return nil }
        if let id = link.videoID { return id }
        AUNLog.network.info("Universal link without a viewer screen, opening Home")
        return nil
    }

    public static func liveStreamID(for url: URL) -> String? {
        guard let link = AppLink.parse(url) else { return nil }
        return link.liveStreamID
    }
}
