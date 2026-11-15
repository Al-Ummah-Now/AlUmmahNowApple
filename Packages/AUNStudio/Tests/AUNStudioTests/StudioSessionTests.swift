import AUNCoreBridge
import Foundation
import Testing

@testable import AUNStudio

@MainActor
struct StudioSessionTests {
    private struct CancellingAuthenticator: WebAuthenticating {
        func authenticate(_ request: SignInRequest) async throws -> URL { throw CoreError.cancelled }
    }

    private func defaults() -> UserDefaults {
        let name = "studio-session-\(UUID().uuidString)"
        return UserDefaults(suiteName: name)!
    }

    private func session(signedIn: Bool = false, authenticator: any WebAuthenticating = FixtureWebAuthenticator())
        -> StudioSession
    {
        StudioSession(services: .fixtures(signedIn: signedIn), authenticator: authenticator, defaults: defaults())
    }

    @Test func startsSignedOutWithoutAccounts() async {
        let session = session()
        await session.start()
        #expect(session.phase == .signedOut)
        #expect(session.channel == nil)
    }

    @Test func signInLoadsUploadableChannelsAndPicksTheMainOne() async {
        let session = session()
        await session.start()
        await session.signIn()
        #expect(session.phase == .signedIn)
        #expect(session.account?.id == FixtureAccountService.creator.id)
        #expect(session.allChannels.count == 3)
        #expect(session.channels.map(\.id) == ["fixture-channel", "fixture-channel-2"])
        #expect(session.channel?.id == "fixture-channel")
    }

    @Test func thePickedChannelIsRememberedPerAccount() async {
        let store = defaults()
        let services = StudioServices.fixtures(signedIn: true)
        let first = StudioSession(services: services, authenticator: FixtureWebAuthenticator(), defaults: store)
        await first.start()
        await first.select(FixtureStudioService.channels[1])
        let second = StudioSession(services: services, authenticator: FixtureWebAuthenticator(), defaults: store)
        await second.start()
        #expect(second.channel?.id == "fixture-channel-2")
    }

    @Test func aStudioLinkPicksItsChannelAndSection() async {
        let session = session(signedIn: true)
        await session.start()
        await session.open(StudioLink(channelID: "fixture-channel-2", section: .analytics))
        #expect(session.channel?.id == "fixture-channel-2")
        #expect(session.linkedSection == .analytics)
        let serial = session.linkSerial
        session.consumeLink()
        #expect(session.linkedSection == nil)

        // A channel the account cannot upload to keeps the current one; the section still opens.
        await session.open(StudioLink(channelID: "fixture-channel-3", section: .content))
        #expect(session.channel?.id == "fixture-channel-2")
        #expect(session.linkedSection == .content)
        #expect(session.linkSerial == serial + 1)
    }

    @Test func aLinkBeforeTheChannelsLoadAppliesOnceTheyDo() async {
        let session = session(signedIn: true)
        await session.open(StudioLink(channelID: "fixture-channel-2", section: .content))
        await session.start()
        #expect(session.channel?.id == "fixture-channel-2")
        #expect(session.linkedSection == .content)
    }

    @Test func linkSectionsMapToTheShells() {
        #if os(iOS)
            #expect(StudioShell.tab(for: .deleted) == .content)
            #expect(StudioShell.tab(for: .analytics) == .analytics)
        #elseif os(macOS)
            #expect(StudioShell.section(for: .deleted) == .deleted)
            #expect(StudioShell.section(for: .home) == .home)
        #endif
    }

    @Test func cancellingSignInShowsNoError() async {
        let session = session(authenticator: CancellingAuthenticator())
        await session.start()
        await session.signIn()
        #expect(session.phase == .signedOut)
        #expect(session.notice == nil)
    }

    @Test func addingAndSwitchingAccounts() async {
        let session = session(signedIn: true)
        await session.start()
        await session.signIn(addingAccount: true)
        #expect(session.accounts.count == 2)
        #expect(session.account?.id == "fixture-account-1")
        await session.switchAccount(to: FixtureAccountService.creator.id)
        #expect(session.account?.id == FixtureAccountService.creator.id)
        #expect(session.channel != nil)
    }

    @Test func signingOutTheLastAccountReturnsToSignIn() async {
        let session = session(signedIn: true)
        await session.start()
        await session.signIn(addingAccount: true)
        await session.signOut("fixture-account-1")
        #expect(session.phase == .signedIn)
        #expect(session.account?.id == FixtureAccountService.creator.id)
        await session.signOut(FixtureAccountService.creator.id)
        #expect(session.phase == .signedOut)
        #expect(session.accounts.isEmpty)
        #expect(session.channel == nil)
    }
}
