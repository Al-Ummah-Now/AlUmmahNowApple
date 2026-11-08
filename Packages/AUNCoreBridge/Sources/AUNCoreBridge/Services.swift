import Foundation

public enum CoreError: Error, Equatable, Sendable {
    case http(status: Int)
    case decoding
    case signInRequired
    case notFound
    case upload(String)
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
    public var auth: any AuthSessionProviding
    public var uploads: any UploadEngine

    public init(
        environment: AppEnvironment, catalog: any CatalogServicing, auth: any AuthSessionProviding, uploads: any UploadEngine
    ) {
        self.environment = environment
        self.catalog = catalog
        self.auth = auth
        self.uploads = uploads
    }

    /// Interim implementation in Swift. The Rust XCFramework replaces this one factory.
    public static func temporaryNative(environment: AppEnvironment, session: URLSession = .shared) -> CoreBridge {
        let auth = GuestAuthSession()
        return CoreBridge(
            environment: environment,
            catalog: NativeCatalogService(baseURL: environment.apiBaseURL, session: session),
            auth: auth,
            uploads: NativeTUSUploadEngine(session: session)
        )
    }

    /// Hermetic bridge for UI tests, snapshots and previews.
    public static func fixtures() -> CoreBridge {
        CoreBridge(
            environment: .qa, catalog: FixtureCatalogService(), auth: GuestAuthSession(),
            uploads: NativeTUSUploadEngine(session: .shared))
    }
}
