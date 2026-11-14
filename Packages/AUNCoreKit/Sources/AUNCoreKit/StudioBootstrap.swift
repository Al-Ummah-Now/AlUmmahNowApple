import AUNCoreBridge
import Foundation

public enum StudioBootstrap {
    /// One per process: iOS reconnects the background upload session by its identifier.
    public static let liveTransfer = TUSTransfer.live()

    /// Fixture runs start from empty preferences, so UI tests never see an earlier test's choices.
    public static func preferences(defaults: UserDefaults = .standard) -> UserDefaults {
        guard defaults.bool(forKey: "AUNUseFixtures") else { return defaults }
        let name = "net.alummahnow.studio.fixtures"
        defaults.removePersistentDomain(forName: name)
        return UserDefaults(suiteName: name) ?? defaults
    }

    /// Fixture runs sign in without a browser.
    @MainActor public static func usesFixtures(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: "AUNUseFixtures")
    }

    /// The Studio services for this build. `-AUNUseFixtures YES` selects hermetic data for UI tests,
    /// `-AUNFixtureSignedIn YES` starts them signed in, and `-AUNFixtureAccountState invitation|pendingDeletion` starts
    /// the account without a creator tier or with its videos data pending deletion, and
    /// `-AUNFixturePasskey success|cancel|noCredential|stepUp|rateLimited` picks how passkey calls answer.
    public static func services(
        defaults: UserDefaults = .standard, bundle: Bundle = .main
    ) -> StudioServices {
        if defaults.bool(forKey: "AUNUseFixtures") {
            let state = defaults.string(forKey: "AUNFixtureAccountState").flatMap(FixtureStudioService.AccountState.init)
            let passkey = defaults.string(forKey: "AUNFixturePasskey").flatMap(FixturePasskeyService.Outcome.init)
            return .fixtures(
                signedIn: defaults.bool(forKey: "AUNFixtureSignedIn"), accountState: state ?? .creator,
                passkey: passkey ?? .success)
        }
        let environment = AppEnvironment.fromInfoDictionary(bundle.infoDictionary)
        do {
            let accounts = try CoreAccountService.live(
                environment: environment, bundleID: bundle.bundleIdentifier ?? "net.alummahnow.studio")
            return StudioServices(
                environment: environment, accounts: accounts,
                studio: NativeStudioService(baseURL: environment.apiBaseURL, accounts: accounts), transfer: liveTransfer,
                search: CoreSearchService(accounts: accounts, baseURL: environment.apiBaseURL))
        } catch {
            AUNLog.studio.fault("Studio services could not start: \(error)")
            return StudioServices(
                environment: environment, accounts: FixtureAccountService(),
                studio: NativeStudioService(baseURL: environment.apiBaseURL, accounts: FixtureAccountService()),
                transfer: liveTransfer, search: FixtureSearchService())
        }
    }
}
