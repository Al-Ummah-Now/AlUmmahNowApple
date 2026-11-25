import Foundation

public enum CoreError: Error, Equatable, Sendable {
    case http(status: Int)
    case decoding
    case signInRequired
    case notFound
    case upload(String)
    case forbidden
    case offline
    case cancelled
    /// The server refused the input; the message is safe to show.
    case invalid(String)
    /// The server refused because of a plan, a creator tier or the account's state; see `Refusal`.
    case refused(Refusal)
    /// 409 with the server's `error` code (`too_late`, `draft_exists`, `draft_conflict`…) and, for `files_missing`,
    /// the paths it lists.
    case conflict(String, missing: [String] = [])
    /// 404 `feature_off`: the feature is switched off, not configured or not in the tier. Hide what asked, say nothing.
    case featureOff

    /// Off, not configured or not in the person's tier (`feature_off`, 402, `upgrade_required`, `uploads_by_invitation`):
    /// the entry point disappears and no text is shown (owner rule 2026-11-16).
    public var hidesEntryPoint: Bool {
        switch self {
        case .featureOff: true
        case .http(let status): status == 402
        case .refused(let refusal): refusal.hidesEntryPoint
        default: false
        }
    }

    /// The refusal, when the server refused with a code. Retrying it changes nothing.
    public var refusal: Refusal? {
        if case .refused(let refusal) = self { return refusal }
        return nil
    }
}

/// A refusal the server explains with a `code` (`402`, `403`, `410` or `429` with a JSON body), so the app can say why
/// instead of "something went wrong". `message` is the server's own text when it is meant for people (a plan's
/// `message`); apps show their localized text for every other code.
public struct Refusal: Equatable, Sendable {
    public var code: String
    public var message: String?
    /// Seconds, for `upload_limit`.
    public var retryAfter: Int?
    /// The plan entitlement that refused it, for `upgrade_required`.
    public var entitlement: String?
    /// Latest Creator Terms version returned on 409 `terms_version_changed`.
    public var currentVersion: String?

    public init(
        code: String, message: String? = nil, retryAfter: Int? = nil, entitlement: String? = nil,
        currentVersion: String? = nil
    ) {
        self.code = code
        self.message = message
        self.retryAfter = retryAfter
        self.entitlement = entitlement
        self.currentVersion = currentVersion
    }

    /// No creator tier: uploads and channel creation are by invitation (403).
    public static let uploadsByInvitation = "uploads_by_invitation"
    /// The tier's channel limit is reached (403).
    public static let channelLimit = "channel_limit"
    /// The tier's hourly or daily upload limit is reached (429, `retryAfter`).
    public static let uploadLimit = "upload_limit"
    /// The plan does not include this (402, `entitlement`, `message`).
    public static let upgradeRequired = "upgrade_required"
    /// An admin ran "Delete videos data": reads work, writes are refused until it is restored (403).
    public static let accountPendingDeletion = "videos_account_pending_deletion"
    /// An admin banned the account on videos: reads work, writes are refused (403).
    public static let banned = "videos_banned"
    /// Dislikes were removed from the product (410).
    public static let dislikesDisabled = "dislikes_disabled"
    /// The creator has not accepted the current Creator Terms & Community Guidelines (403).
    public static let termsRequired = "terms_required"
    /// The Creator Terms version changed before acceptance was recorded (409, `currentVersion`).
    public static let termsVersionChanged = "terms_version_changed"

    /// A gated API's answer while its feature is off for the caller (404, no message); see `CoreError.featureOff`.
    public static let featureOff = "feature_off"

    public static let known: Set<String> = [
        uploadsByInvitation, channelLimit, uploadLimit, upgradeRequired, accountPendingDeletion, banned, dislikesDisabled,
        termsRequired, termsVersionChanged,
    ]

    /// The refusal in an error body, if it carries a known code (in `code`, or in `error` as `upgrade_required` does).
    public static func parse(_ data: Data) -> Refusal? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let candidates = [object["code"], object["error"]].compactMap { $0 as? String }
        guard let code = candidates.first(where: known.contains) else { return nil }
        let message = (object["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentVersion = (object["currentVersion"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return Refusal(
            code: code, message: message?.isEmpty == false ? message : nil,
            retryAfter: (object["retryAfter"] as? NSNumber)?.intValue, entitlement: object["entitlement"] as? String,
            currentVersion: currentVersion?.isEmpty == false ? currentVersion : nil)
    }

    /// A tier or plan refusal: nothing to say, the entry point is hidden.
    public var hidesEntryPoint: Bool { code == Self.upgradeRequired || code == Self.uploadsByInvitation }

    /// Writes are refused for the whole account until an admin acts; stop retrying and say so once.
    public var isAccountState: Bool { code == Self.accountPendingDeletion || code == Self.banned }
}

/// Read access to the public catalog. `aun-api` replaces the native implementation.
public protocol CatalogServicing: Sendable {
    func homeRails(limit: Int) async throws -> [HomeRail]
    func video(id: String) async throws -> Video
    func subtitles(videoID: String) async throws -> [SubtitleTrack]
    func chapters(videoID: String) async throws -> [Chapter]
    func subtitleText(url: URL) async throws -> String
}

/// Sign-in state. `aun-auth` (OAuth 2 + PKCE, device flow) replaces `GuestAuthSession`.
public protocol AuthSessionProviding: Sendable {
    func accessToken() async throws -> String?
}

public struct GuestAuthSession: AuthSessionProviding {
    public init() {}
    public func accessToken() async throws -> String? { nil }
}

/// The services an app needs. Features only see these protocols.
public struct CoreBridge: Sendable {
    public var environment: AppEnvironment
    public var catalog: any CatalogServicing
    public var live: any LiveServicing
    public var auth: any AuthSessionProviding
    public var uploads: any UploadEngine
    public var siteTheme: any SiteThemeServicing

    public init(
        environment: AppEnvironment, catalog: any CatalogServicing, live: any LiveServicing, auth: any AuthSessionProviding,
        uploads: any UploadEngine, siteTheme: any SiteThemeServicing
    ) {
        self.environment = environment
        self.catalog = catalog
        self.live = live
        self.auth = auth
        self.uploads = uploads
        self.siteTheme = siteTheme
    }

    /// Interim implementation in Swift. The Rust XCFramework replaces this one factory.
    public static func temporaryNative(environment: AppEnvironment, session: URLSession = .shared) -> CoreBridge {
        let auth = GuestAuthSession()
        return CoreBridge(
            environment: environment,
            catalog: NativeCatalogService(baseURL: environment.apiBaseURL, session: session),
            live: NativeLiveService(baseURL: environment.apiBaseURL, session: session),
            auth: auth,
            uploads: NativeTUSUploadEngine(session: session),
            siteTheme: NativeSiteThemeService(adminAPIBaseURL: environment.adminAPIBaseURL, session: session)
        )
    }

    /// Hermetic bridge for UI tests, snapshots and previews. The site theme is the one given, Fawanees by default;
    /// `playable` streams a bundled clip (store screenshots); without `live` nothing is on air and its switches are off.
    public static func fixtures(
        siteTheme: String = "fawanees", playable: Bool = false, live: Bool = false, language: AppLanguage = .en
    ) -> CoreBridge {
        CoreBridge(
            environment: .qa, catalog: FixtureCatalogService(playable: playable),
            live: FixtureLiveService(isOff: !live, playable: playable, language: language), auth: GuestAuthSession(),
            uploads: NativeTUSUploadEngine(session: .shared), siteTheme: FixedSiteThemeService(siteTheme))
    }
}
