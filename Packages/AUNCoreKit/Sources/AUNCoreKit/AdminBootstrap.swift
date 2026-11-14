import AUNCoreBridge
import Foundation

/// The Admin app's services. `-AUNUseFixtures YES` selects the in-memory queue (UI tests); `-AUNFixtureRole
/// reviewer|senior|viewer` picks who is signed in, `-AUNFixtureSignedIn YES` starts signed in and
/// `-AUNFixtureOffline YES` starts with the device offline, `-AUNFixturePasskey success|cancel|noCredential|stepUp|rateLimited`
/// picks how passkey calls answer.
public enum AdminBootstrap {
    public static let callbackScheme = "alummahnow-admin"

    @MainActor public static func usesFixtures(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: "AUNUseFixtures")
    }

    public static func services(defaults: UserDefaults = .standard, bundle: Bundle = .main) -> AdminServices {
        if defaults.bool(forKey: "AUNUseFixtures") {
            let role = defaults.string(forKey: "AUNFixtureRole").flatMap(FixtureReviewService.Role.init) ?? .reviewer
            // Offline is the device's network state (NetworkMonitor): the fixture queue still answers, the buttons do not.
            let review = FixtureReviewService(role: role)
            let account = StudioAccount(
                id: role == .senior ? "fx-senior" : "fx-reviewer", email: "reviewer@example.org",
                displayName: role == .senior ? "Fixture Senior" : "Fixture Reviewer")
            let accounts = FixtureAccountService(signedIn: defaults.bool(forKey: "AUNFixtureSignedIn") ? [account] : [])
            let passkey = defaults.string(forKey: "AUNFixturePasskey").flatMap(FixturePasskeyService.Outcome.init)
            return AdminServices(
                accounts: accounts, review: review, push: review,
                passkeys: FixturePasskeyService(outcome: passkey ?? .success))
        }
        let environment = AppEnvironment.fromInfoDictionary(bundle.infoDictionary)
        let accounts: any AccountServicing
        do {
            accounts = try CoreAccountService.live(
                environment: environment, bundleID: bundle.bundleIdentifier ?? "net.alummahnow.admin",
                callbackScheme: callbackScheme)
        } catch {
            AUNLog.admin.fault("Admin sign-in could not start: \(error)")
            accounts = FixtureAccountService()
        }
        let native = NativeReviewService(
            adminAPI: environment.adminAPIBaseURL, videosAPI: environment.apiBaseURL, accounts: accounts)
        return AdminServices(
            accounts: accounts, review: native, push: native, passkeys: NativePasskeyService(),
            authIssuer: environment.authIssuer)
    }

    /// A stable id for this install (the push registry key): 8–64 of [A-Za-z0-9_-].
    public static func installID(defaults: UserDefaults = .standard) -> String {
        if let id = defaults.string(forKey: "AUNAdminInstallID") { return id }
        let id = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        defaults.set(id, forKey: "AUNAdminInstallID")
        return id
    }
}
