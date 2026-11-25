import Foundation

/// Where this build was installed from; it decides what Update does (wiki AUN-APP-UPDATES §2.3).
public enum AppInstallSource: String, Sendable {
    case appStore = "appstore"
    case testFlight = "testflight"
    /// Installs its own updates (Studio for Mac with Sparkle)
    case direct
    /// Downloaded by hand, or a build that can't install updates
    case managed
}

public struct AppUpdateText: Codable, Hashable, Sendable {
    public var en: String
    public var ar: String
    public init(en: String, ar: String) {
        self.en = en
        self.ar = ar
    }
}

public enum AppUpdateAction: Hashable, Sendable {
    /// Open the app's page in its store
    case store(URL)
    /// Verify the signed manifest, then install
    case install(manifest: URL, tag: String)
    /// Open the one compiled-in page
    case download
}

/// What to show after a check.
public struct AppUpdatePrompt: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        /// The bar; closing it hides this version
        case notice
        /// Below the minimum, but this build can't get an update yet: a bar that can't be closed
        case requiredSoon
        /// Below the minimum and the update is there: the whole window
        case forced
    }

    public var kind: Kind
    public var version: String?
    public var notes: AppUpdateText?
    public var message: AppUpdateText?
    public var action: AppUpdateAction?

    public init(
        kind: Kind, version: String? = nil, notes: AppUpdateText? = nil, message: AppUpdateText? = nil,
        action: AppUpdateAction? = nil
    ) {
        self.kind = kind
        self.version = version
        self.notes = notes
        self.message = message
        self.action = action
    }
}

public struct AppUpdateCheck: Hashable, Sendable {
    /// The server's `appUpdates` switch
    public var enabled: Bool
    /// Nil: show nothing
    public var prompt: AppUpdatePrompt?
    /// Hours until the next check, 1 to 48
    public var checkHours: Int

    public init(enabled: Bool, prompt: AppUpdatePrompt?, checkHours: Int) {
        self.enabled = enabled
        self.prompt = prompt
        self.checkHours = checkHours
    }
}

/// Asks our API whether a newer version is out. Nothing is ever downloaded or installed through this protocol.
public protocol AppUpdateChecking: Sendable {
    /// Throws when the server can't be reached or its answer can't be read; try again at the next interval.
    func check() async throws -> AppUpdateCheck
    /// Without a network: the bar for a minimum already seen, else nothing. Never the forced screen.
    func offlinePrompt() async -> AppUpdatePrompt?
    /// The notice was closed: hidden for this version.
    func dismiss(version: String) async
}

/// The fields the apps read of `update` in `GET /api/v1/app-config` (wiki §4.1). Unknown fields and values are ignored.
struct AppUpdateAnswer: Decodable {
    var enabled = false
    var status = "ok"
    var minimumVersion = "0.0.0"
    var latestVersion: String?
    var storeUrl: String?
    var notes: AppUpdateText?
    var message: AppUpdateText?
    var action = "none"
    var available: Bool?
    var checkHours: Int?

    private enum Key: String, CodingKey {
        case enabled, status, minimumVersion, latestVersion, storeUrl, notes, message, action, available, checkHours
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? "ok"
        minimumVersion = try c.decodeIfPresent(String.self, forKey: .minimumVersion) ?? "0.0.0"
        latestVersion = try c.decodeIfPresent(String.self, forKey: .latestVersion)
        storeUrl = try c.decodeIfPresent(String.self, forKey: .storeUrl)
        notes = try c.decodeIfPresent(AppUpdateText.self, forKey: .notes)
        message = try c.decodeIfPresent(AppUpdateText.self, forKey: .message)
        action = try c.decodeIfPresent(String.self, forKey: .action) ?? "none"
        available = try c.decodeIfPresent(Bool.self, forKey: .available)
        checkHours = try c.decodeIfPresent(Int.self, forKey: .checkHours)
    }

    var hours: Int { min(48, max(1, checkHours ?? 6)) }
}

/// The rules of aun-core's `decide` for a build that only ever opens its store (wiki §3.7, §7).
struct StoreUpdateDecider {
    /// What the app remembers between checks.
    struct State: Codable, Hashable, Sendable {
        var dismissed: [String] = []
        /// The last `required` the app saw, so it holds offline
        var requiredMinimum: String?
    }

    var source: AppInstallSource
    var installed: String

    func decide(_ answer: AppUpdateAnswer, state: inout State) -> AppUpdatePrompt? {
        guard answer.enabled, let mine = AppVersion(installed), let minimum = AppVersion(answer.minimumVersion) else {
            if !answer.enabled { state.requiredMinimum = nil }
            return nil
        }
        let below = mine < minimum
        state.requiredMinimum = below ? answer.minimumVersion : nil
        let latest = answer.latestVersion.flatMap(AppVersion.init)
        // A store build opens its store and nothing else: install, download and notice are not for it
        let page = answer.action == "store" ? storePage(answer.storeUrl) : nil
        let helps = latest.map { !below || $0 >= minimum } ?? false
        let obtainable = page != nil && answer.available == true && helps
        var prompt = AppUpdatePrompt(
            kind: .notice, version: answer.latestVersion, notes: answer.notes, message: answer.message,
            action: obtainable ? page.map(AppUpdateAction.store) : nil)
        if below {
            prompt.kind = obtainable ? .forced : .requiredSoon
            return prompt
        }
        guard answer.status == "recommended", obtainable, let latest, mine < latest,
            !state.dismissed.contains(where: { AppVersion($0) == latest })
        else { return nil }
        return prompt
    }

    /// A bar for a minimum already seen; never the forced screen, which needs the store to have the update.
    func offline(_ state: State) -> AppUpdatePrompt? {
        guard let mine = AppVersion(installed), let minimum = state.requiredMinimum.flatMap(AppVersion.init), mine < minimum
        else {
            return nil
        }
        return AppUpdatePrompt(kind: .requiredSoon)
    }

    /// TestFlight is one fixed link. The App Store page is Apple's own (from its lookup); any other host is refused.
    func storePage(_ text: String?) -> URL? {
        switch source {
        case .testFlight: return URL(string: "itms-beta://")
        case .appStore:
            guard let text, let url = URL(string: text), url.scheme == "https", url.host() == "apps.apple.com",
                url.user() == nil, url.port == nil
            else { return nil }
            return url
        case .direct, .managed: return nil
        }
    }
}
