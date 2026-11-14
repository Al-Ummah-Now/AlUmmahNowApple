import AUNCoreBridge
import AUNStudio
import Foundation
import Testing

@testable import AUNAdmin

@MainActor
struct AdminPasskeyTests {
    private func session(
        signedIn: Bool = false, passcode: Bool = true, passkey: FixturePasskeyService.Outcome = .success,
        ceremony: FixturePasskeyAuthenticator.Outcome = .success
    ) -> AdminSession {
        let review = FixtureReviewService(role: .reviewer)
        let account = StudioAccount(id: "fx-reviewer", displayName: "Fixture Reviewer")
        let services = AdminServices(
            accounts: FixtureAccountService(signedIn: signedIn ? [account] : []), review: review, push: review,
            passkeys: FixturePasskeyService(outcome: passkey))
        return AdminSession(
            services: services, authenticator: FixtureWebAuthenticator(),
            passkeyAuthenticator: FixturePasskeyAuthenticator(outcome: ceremony),
            lock: FixtureDeviceUnlock(passcode: passcode), installID: "install-test-1",
            network: NetworkMonitor(forcedOffline: false))
    }

    @Test func passkeySignInRunsTheStaffCheck() async {
        let session = session()
        await session.start()
        await session.signInWithPasskey()
        #expect(session.phase == .ready)
        #expect(session.stepUpIsFresh)
        #expect(session.passkeyDialog == nil)
    }

    @Test func passkeySignInNeedsADevicePasscodeToo() async {
        let session = session(passcode: false)
        await session.start()
        await session.signInWithPasskey()
        #expect(session.phase == .signedOut)
        #expect(session.notice == "admin.signIn.noPasscode")
    }

    @Test func cancelIsSilentAndNoPasskeyOffersAnotherWay() async {
        let cancelled = session(ceremony: .cancel)
        await cancelled.start()
        await cancelled.signInWithPasskey()
        #expect(cancelled.passkeyDialog == nil)
        #expect(cancelled.notice == nil)

        let unknown = session(passkey: .noCredential)
        await unknown.start()
        await unknown.signInWithPasskey()
        #expect(unknown.passkeyDialog?.messageKey == "passkey.noCredential")
        await unknown.perform(.signInAnotherWay(addingAccount: false))
        #expect(unknown.phase == .ready)
    }

    @Test func addingAPasskeySignsInAgainWhenTheSignInIsOld() async {
        let session = session(signedIn: true, passkey: .stepUp)
        await session.start()
        await session.unlock(reason: "test")
        await session.addPasskey()
        #expect(session.passkeyDialog?.action == .signInAgain)
        await session.perform(.signInAgain)
        #expect(session.passkeyDialog == .added)
        #expect(session.stepUpIsFresh)
    }
}
