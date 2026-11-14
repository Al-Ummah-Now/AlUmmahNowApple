import AUNCoreBridge
import AuthenticationServices
import Foundation
import Testing

@testable import AUNStudio

/// Records every call, and answers with `stepUps` step-up demands before options succeed.
private actor RecordingPasskeyService: PasskeyServicing {
    var calls: [String] = []
    var signInClient: String?
    var signInChallenge: String?
    var verifiedAssertion: PasskeyAssertion?
    var tokens: [String] = []
    private var stepUps: Int
    private let verifyError: PasskeyError?

    init(stepUps: Int = 0, verifyError: PasskeyError? = nil) {
        self.stepUps = stepUps
        self.verifyError = verifyError
    }

    func signInOptions(issuer: URL, clientID: String, codeChallenge: String) async throws -> PasskeyRequestOptions {
        calls.append("options \(issuer.host() ?? "")")
        signInClient = clientID
        signInChallenge = codeChallenge
        return PasskeyRequestOptions(challengeID: "k1", challenge: Data("c".utf8), rpID: "qa.alummahnow.net")
    }

    func verifySignIn(issuer: URL, challengeID: String, clientID: String, assertion: PasskeyAssertion) async throws
        -> String
    {
        calls.append("verify \(challengeID)")
        verifiedAssertion = assertion
        if let verifyError { throw verifyError }
        return "passkey-code"
    }

    func registrationOptions(issuer: URL, accessToken: String) async throws -> PasskeyCreationOptions {
        calls.append("register/options")
        tokens.append(accessToken)
        if stepUps > 0 {
            stepUps -= 1
            throw PasskeyError.stepUpRequired
        }
        return PasskeyCreationOptions(
            challengeID: "k2", challenge: Data("c".utf8), rpID: "qa.alummahnow.net", userID: Data("u".utf8),
            userName: "creator@example.org")
    }

    func verifyRegistration(
        issuer: URL, accessToken: String, challengeID: String, registration: PasskeyRegistration, name: String?
    ) async throws -> PasskeyRecord {
        calls.append("register/verify \(challengeID)")
        return PasskeyRecord(id: "p1")
    }
}

/// Accounts whose sign-ins always come back as `next`, and that remember the redirect.
private actor ScriptedAccounts: AccountServicing {
    var redirects: [URL] = []
    private var stored: [StudioAccount]
    private var active: String?
    private let next: StudioAccount

    init(signedIn: StudioAccount?, next: StudioAccount) {
        stored = signedIn.map { [$0] } ?? []
        active = signedIn?.id
        self.next = next
    }

    func accounts() -> [StudioAccount] { stored }
    func activeAccount() -> StudioAccount? { stored.first { $0.id == active } }
    func beginSignIn(_ prompt: SignInPrompt) -> SignInRequest {
        SignInRequest(url: FixtureAccountService.authorizeURL, callbackScheme: FixtureAccountService.callbackScheme)
    }
    func completeSignIn(redirect: URL) -> StudioAccount {
        redirects.append(redirect)
        if !stored.contains(where: { $0.id == next.id }) { stored.append(next) }
        active = next.id
        return next
    }
    func switchAccount(to id: String) throws -> StudioAccount { throw CoreError.notFound }
    func signOut(_ id: String) {}
    func setActiveChannel(_ channelID: String?) {}
    func accessToken() -> String? { active.map { "token-\($0)" } }
}

private struct ThrowingPasskeyAuthenticator: PasskeyAuthenticating {
    let error: any Error
    func assert(_ options: PasskeyRequestOptions) async throws -> PasskeyAssertion { throw error }
    func register(_ options: PasskeyCreationOptions) async throws -> PasskeyRegistration { throw error }
}

@MainActor
struct PasskeyFlowTests {
    private func session(
        signedIn: Bool = false, service: any PasskeyServicing = FixturePasskeyService(),
        authenticator: any PasskeyAuthenticating = FixturePasskeyAuthenticator(),
        accounts: (any AccountServicing)? = nil
    ) -> StudioSession {
        var services = StudioServices.fixtures(signedIn: signedIn)
        services.passkeys = service
        if let accounts { services.accounts = accounts }
        return StudioSession(
            services: services, authenticator: FixtureWebAuthenticator(), passkeyAuthenticator: authenticator,
            defaults: UserDefaults(suiteName: "passkey-\(UUID().uuidString)")!)
    }

    @Test func signInSendsThePKCEChallengeAndCompletesWithTheCodeAndState() async throws {
        let service = RecordingPasskeyService()
        let creator = FixtureAccountService.creator
        let accounts = ScriptedAccounts(signedIn: nil, next: creator)
        let authenticator = FixturePasskeyAuthenticator()
        let session = session(service: service, authenticator: authenticator, accounts: accounts)
        await session.start()
        await session.signInWithPasskey()
        #expect(session.phase == .signedIn)
        #expect(session.account?.id == creator.id)
        #expect(session.passkeyDialog == nil)
        #expect(await service.calls == ["options auth.fixtures.invalid", "verify k1"])
        #expect(await service.signInClient == "fixture-client")
        #expect(await service.signInChallenge == "fixture-challenge")
        #expect(await service.verifiedAssertion?.credentialID == Data("fixture-credential".utf8))
        let redirect = try #require(await accounts.redirects.first)
        #expect(redirect.absoluteString == "alummahnow-studio://auth/callback?code=passkey-code&state=fixture-state")
        // The same requests the system sheet would get: platform passkeys and security keys.
        #expect(authenticator.presentedRequests.count == 2)
    }

    @Test func cancellingTheSheetShowsNothing() async {
        let session = session(authenticator: FixturePasskeyAuthenticator(outcome: .cancel))
        await session.start()
        await session.signInWithPasskey()
        #expect(session.phase == .signedOut)
        #expect(session.passkeyDialog == nil)
        #expect(session.notice == nil)
    }

    @Test func noPasskeyForTheAccountOffersAnotherWay() async {
        let session = session(service: FixturePasskeyService(outcome: .noCredential))
        await session.start()
        await session.signInWithPasskey()
        #expect(session.phase == .signedOut)
        #expect(session.passkeyDialog?.messageKey == "passkey.noCredential")
        #expect(session.passkeyDialog?.action == .signInAnotherWay(addingAccount: false))
        // "Sign in another way" is the unchanged browser sign-in.
        await session.perform(.signInAnotherWay(addingAccount: false))
        #expect(session.passkeyDialog == nil)
        #expect(session.phase == .signedIn)
    }

    @Test func tooManyTriesSaysSo() async {
        let session = session(service: FixturePasskeyService(outcome: .rateLimited))
        await session.start()
        await session.signInWithPasskey()
        #expect(session.passkeyDialog?.messageKey == "passkey.rateLimited")
    }

    @Test func addingAPasskeyToTheActiveAccount() async {
        let service = RecordingPasskeyService()
        let session = session(signedIn: true, service: service)
        await session.start()
        await session.addPasskey()
        #expect(session.passkeyDialog == .added)
        #expect(await service.calls == ["register/options", "register/verify k2"])
        #expect(await service.tokens == ["fixture-token"])
    }

    @Test func stepUpAsksToSignInAgainThenRetries() async {
        let service = RecordingPasskeyService(stepUps: 1)
        let session = session(signedIn: true, service: service)
        await session.start()
        await session.addPasskey()
        #expect(session.passkeyDialog?.messageKey == "passkey.stale")
        #expect(session.passkeyDialog?.action == .signInAgain)
        await session.perform(.signInAgain)
        #expect(session.passkeyDialog == .added)
        #expect(session.account?.id == FixtureAccountService.creator.id)
        #expect(await service.calls == ["register/options", "register/options", "register/verify k2"])
    }

    @Test func aSecondStepUpAfterSigningInAgainFailsInsteadOfLooping() async {
        let session = session(signedIn: true, service: RecordingPasskeyService(stepUps: 2))
        await session.start()
        await session.addPasskey()
        await session.perform(.signInAgain)
        #expect(session.passkeyDialog?.messageKey == "passkey.addFailed")
        #expect(session.passkeyDialog?.action == nil)
    }

    @Test func signingInAgainAsAnotherAccountAddsNothing() async {
        let creator = FixtureAccountService.creator
        let other = StudioAccount(id: "other", email: "other@example.org")
        let service = RecordingPasskeyService(stepUps: 1)
        let session = session(
            signedIn: true, service: service, accounts: ScriptedAccounts(signedIn: creator, next: other))
        await session.start()
        await session.addPasskey()
        await session.perform(.signInAgain)
        #expect(session.passkeyDialog == .otherAccount(creator.label))
        #expect(session.account?.id == "other")
        #expect(await service.calls == ["register/options"])
    }

    @Test func registrationErrorsBecomeInAppMessages() async {
        let session = session(
            signedIn: true, authenticator: ThrowingPasskeyAuthenticator(error: PasskeyError.alreadyRegistered))
        await session.start()
        await session.addPasskey()
        #expect(session.passkeyDialog?.messageKey == "passkey.exists")
    }
}

struct PasskeyDialogTests {
    @Test func signInFailures() {
        #expect(PasskeyDialog.signInFailure(PasskeyError.cancelled) == nil)
        #expect(PasskeyDialog.signInFailure(CoreError.cancelled) == nil)
        #expect(PasskeyDialog.signInFailure(PasskeyError.notAssociated)?.messageKey == "passkey.notAssociated")
        #expect(PasskeyDialog.signInFailure(PasskeyError.offline)?.action == nil)
        #expect(PasskeyDialog.signInFailure(CoreError.http(status: 400))?.messageKey == "passkey.signInFailed")
        #expect(
            PasskeyDialog.signInFailure(PasskeyError.failed(nil), addingAccount: true)?.action
                == .signInAnotherWay(addingAccount: true))
    }

    @Test func registerFailures() {
        #expect(PasskeyDialog.registerFailure(PasskeyError.cancelled) == nil)
        #expect(PasskeyDialog.registerFailure(PasskeyError.limit)?.messageKey == "passkey.limit")
        #expect(PasskeyDialog.registerFailure(PasskeyError.rateLimited(retryAfter: 5))?.messageKey == "passkey.rateLimited")
        #expect(PasskeyDialog.registerFailure(PasskeyError.signInRequired)?.action == .signInAgain)
        #expect(PasskeyDialog.registerFailure(PasskeyError.notAssociated)?.messageKey == "passkey.notAssociated.add")
        #expect(PasskeyDialog.registerFailure(CoreError.offline)?.messageKey == "passkey.offline")
    }
}

/// Stops at the seam right before the system sheet: records the requests, then answers like the sheet would.
@MainActor
private final class RecordingPresenter: PasskeyControllerPresenting {
    var requests: [ASAuthorizationRequest] = []
    let error: any Error

    init(error: any Error) { self.error = error }

    func perform(_ requests: [ASAuthorizationRequest]) async throws -> ASAuthorization {
        self.requests = requests
        throw error
    }
}

@MainActor
struct SystemPasskeyAuthenticatorTests {
    private let options = PasskeyRequestOptions(
        challengeID: "k1", challenge: Data("challenge".utf8), rpID: "alummahnow.net",
        allowCredentialIDs: [Data([1, 2])], userVerification: "required")

    @Test func assertionAsksForPlatformPasskeysAndSecurityKeys() throws {
        let requests = SystemPasskeyAuthenticator.assertionRequests(options)
        #expect(requests.count == 2)
        let platform = try #require(requests[0] as? ASAuthorizationPlatformPublicKeyCredentialAssertionRequest)
        #expect(platform.challenge == Data("challenge".utf8))
        #expect(platform.relyingPartyIdentifier == "alummahnow.net")
        #expect(platform.allowedCredentials.map(\.credentialID) == [Data([1, 2])])
        #expect(platform.userVerificationPreference == .required)
        let key = try #require(requests[1] as? ASAuthorizationSecurityKeyPublicKeyCredentialAssertionRequest)
        #expect(key.challenge == Data("challenge".utf8))
        #expect(key.relyingPartyIdentifier == "alummahnow.net")
        #expect(key.allowedCredentials.map(\.credentialID) == [Data([1, 2])])
    }

    @Test func registrationIsAPlatformPasskeyForTheAccount() throws {
        let creation = PasskeyCreationOptions(
            challengeID: "k2", challenge: Data("c".utf8), rpID: "qa.alummahnow.net", userID: Data("u1".utf8),
            userName: "a@example.org", userDisplayName: "A", excludeCredentialIDs: [Data([9])])
        let requests = SystemPasskeyAuthenticator.registrationRequests(creation)
        let request = try #require(requests.first as? ASAuthorizationPlatformPublicKeyCredentialRegistrationRequest)
        #expect(requests.count == 1)
        #expect(request.name == "a@example.org")
        #expect(request.userID == Data("u1".utf8))
        #expect(request.displayName == "A")
        #expect(request.relyingPartyIdentifier == "qa.alummahnow.net")
        #expect(request.userVerificationPreference == .preferred)
    }

    @Test func closingTheSheetIsCancelledAndReachesTheSeam() async {
        let presenter = RecordingPresenter(error: ASAuthorizationError(.canceled))
        let authenticator = SystemPasskeyAuthenticator(presenter: presenter)
        await #expect(throws: PasskeyError.cancelled) { _ = try await authenticator.assert(options) }
        #expect(presenter.requests.count == 2)
    }

    @Test func platformErrors() {
        #expect(SystemPasskeyAuthenticator.map(ASAuthorizationError(.canceled)) == .cancelled)
        #expect(
            SystemPasskeyAuthenticator.map(NSError(domain: ASAuthorizationError.errorDomain, code: 1006))
                == .alreadyRegistered)
        let unassociated = NSError(
            domain: ASAuthorizationError.errorDomain, code: ASAuthorizationError.failed.rawValue,
            userInfo: [
                NSLocalizedFailureReasonErrorKey:
                    "Application with identifier X is not associated with domain alummahnow.net"
            ])
        #expect(SystemPasskeyAuthenticator.map(unassociated) == .notAssociated)
        #expect(SystemPasskeyAuthenticator.map(ASAuthorizationError(.failed)) == .failed("platform"))
        #expect(SystemPasskeyAuthenticator.map(URLError(.timedOut)) == .failed(nil))
    }
}
