import Foundation
import StoreKit

/// Which app, platform and version asks.
public struct AppUpdateIdentity: Hashable, Sendable {
    public var app: String
    public var platform: String
    public var version: String
    public var source: AppInstallSource
    public var beta: Bool
    public var arch: String?

    public init(app: String, platform: String, version: String, source: AppInstallSource, beta: Bool, arch: String? = nil) {
        self.app = app
        self.platform = platform
        self.version = version
        self.source = source
        self.beta = beta
        self.arch = arch
    }

    /// `GET {api}/api/v1/app-config`: no account data, no device id.
    public func request(apiBaseURL: URL) -> URLRequest {
        var query = [
            URLQueryItem(name: "platform", value: platform), URLQueryItem(name: "app", value: app),
            URLQueryItem(name: "version", value: version), URLQueryItem(name: "channel", value: beta ? "beta" : "stable"),
            URLQueryItem(name: "source", value: source.rawValue),
        ]
        if let arch { query.append(URLQueryItem(name: "arch", value: arch)) }
        var request = URLRequest(
            url: apiBaseURL.appending(path: "api/v1/app-config").appending(queryItems: query),
            cachePolicy: .useProtocolCachePolicy, timeoutInterval: 20)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setAUNClient()
        return request
    }
}

/// Where a build from a store came from. Nil: neither the App Store nor TestFlight (a development or downloaded build).
public enum StoreInstallSource {
    public static func current() async -> AppInstallSource? {
        guard let result = try? await AppTransaction.shared else { return nil }
        let transaction =
            switch result {
            case .verified(let value): value
            case .unverified: nil as AppTransaction?
            }
        return transaction.flatMap { source(environment: $0.environment) }
    }

    static func source(environment: AppStore.Environment) -> AppInstallSource? {
        switch environment {
        case .production: .appStore
        case .sandbox: .testFlight
        default: nil
        }
    }
}

/// Update checks for the builds that only open their store: every viewer, Studio and Admin for iPhone and iPad.
public actor NativeAppUpdateService: AppUpdateChecking {
    private static let stateKey = "AUNAppUpdateState"
    private static let dismissedKept = 10
    private let identity: AppUpdateIdentity
    private let apiBaseURL: URL
    private let session: URLSession
    private let defaults: UserDefaults
    private let decider: StoreUpdateDecider

    public init(
        identity: AppUpdateIdentity, apiBaseURL: URL, session: URLSession = .shared, defaults: sending UserDefaults = .standard
    ) {
        self.identity = identity
        self.apiBaseURL = apiBaseURL
        self.session = session
        self.defaults = defaults
        decider = StoreUpdateDecider(source: identity.source, installed: identity.version)
    }

    private struct Body: Decodable { let update: AppUpdateAnswer }

    public func check() async throws -> AppUpdateCheck {
        let (data, response) = try await session.data(for: identity.request(apiBaseURL: apiBaseURL))
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw CoreError.http(status: (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        guard let answer = try? JSONDecoder().decode(Body.self, from: data).update else { throw CoreError.decoding }
        var state = load()
        let prompt = decider.decide(answer, state: &state)
        save(state)
        return AppUpdateCheck(enabled: answer.enabled, prompt: prompt, checkHours: answer.hours)
    }

    public func offlinePrompt() -> AppUpdatePrompt? { decider.offline(load()) }

    public func dismiss(version: String) {
        var state = load()
        state.dismissed.removeAll { $0 == version }
        state.dismissed = Array((state.dismissed + [version]).suffix(Self.dismissedKept))
        save(state)
    }

    private func load() -> StoreUpdateDecider.State {
        defaults.data(forKey: Self.stateKey).flatMap { try? JSONDecoder().decode(StoreUpdateDecider.State.self, from: $0) }
            ?? .init()
    }

    private func save(_ state: StoreUpdateDecider.State) {
        if let data = try? JSONEncoder().encode(state) { defaults.set(data, forKey: Self.stateKey) }
    }
}
