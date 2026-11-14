import Foundation

/// What Studio needs from the outside world. Apps build the live one; tests and previews use fixtures.
public struct StudioServices: Sendable {
    public var environment: AppEnvironment
    public var accounts: any AccountServicing
    public var studio: any StudioServicing
    public var transfer: any TUSTransferring
    public var search: any SearchSuggesting
    /// The auth server's native passkey endpoints (sign-in with a passkey, add a passkey).
    public var passkeys: any PasskeyServicing
    /// False for fixtures: their upload queue lives in a temporary file.
    public var persistsUploads = true

    public init(
        environment: AppEnvironment, accounts: any AccountServicing, studio: any StudioServicing,
        transfer: any TUSTransferring, search: any SearchSuggesting,
        passkeys: any PasskeyServicing = NativePasskeyService()
    ) {
        self.environment = environment
        self.accounts = accounts
        self.studio = studio
        self.transfer = transfer
        self.search = search
        self.passkeys = passkeys
    }

    /// Hermetic services. `signedIn` starts with the fixture creator already signed in, in `accountState`.
    public static func fixtures(
        signedIn: Bool = false, accountState: FixtureStudioService.AccountState = .creator,
        passkey: FixturePasskeyService.Outcome = .success
    ) -> StudioServices {
        var services = StudioServices(
            environment: .qa,
            accounts: FixtureAccountService(signedIn: signedIn ? [FixtureAccountService.creator] : []),
            studio: FixtureStudioService(accountState: accountState), transfer: FixtureTUSTransfer(),
            search: FixtureSearchService(), passkeys: FixturePasskeyService(outcome: passkey))
        services.persistsUploads = false
        return services
    }
}
