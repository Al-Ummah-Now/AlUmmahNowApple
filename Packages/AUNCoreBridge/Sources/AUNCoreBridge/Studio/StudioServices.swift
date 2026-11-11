import Foundation

/// What Studio needs from the outside world. Apps build the live one; tests and previews use fixtures.
public struct StudioServices: Sendable {
    public var environment: AppEnvironment
    public var accounts: any AccountServicing
    public var studio: any StudioServicing

    public init(environment: AppEnvironment, accounts: any AccountServicing, studio: any StudioServicing) {
        self.environment = environment
        self.accounts = accounts
        self.studio = studio
    }

    /// Hermetic services. `signedIn` starts with the fixture creator already signed in.
    public static func fixtures(signedIn: Bool = false) -> StudioServices {
        StudioServices(
            environment: .qa,
            accounts: FixtureAccountService(signedIn: signedIn ? [FixtureAccountService.creator] : []),
            studio: FixtureStudioService())
    }
}
