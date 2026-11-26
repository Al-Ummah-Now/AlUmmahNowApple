import AUNCoreBridge
import Foundation
import Testing

@testable import AUNStudio

/// Uploads while their account is being deleted.
@MainActor
struct DeleteAccountUploadTests {
    /// Counts the chunks and tokens asked for while a deletion runs.
    private final class SlowTransfer: TUSTransferring, @unchecked Sendable {
        var onOrphanCompletion: (@Sendable () -> Void)?
        private let lock = NSLock()
        private var _sends = 0
        private var _cut = 0
        var sends: Int { lock.withLock { _sends } }
        var cut: Int { lock.withLock { _cut } }

        func create(endpoint: URL, headers: [String: String], size: Int64, metadata: [String: String]) async throws -> URL {
            endpoint.appending(path: "upload")
        }
        func offset(of url: URL, headers: [String: String]) async throws -> Int64 { 0 }
        func send(
            chunk file: URL, to url: URL, offset: Int64, headers: [String: String],
            progress: @escaping @Sendable (Int64) -> Void
        ) async throws -> Int64 {
            lock.withLock { _sends += 1 }
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                lock.withLock { _cut += 1 }
                throw error
            }
            return 0
        }
    }

    private func enqueue(_ rig: DeleteAccountRig) throws -> URL {
        let file = FileManager.default.temporaryDirectory.appending(path: "delete-\(UUID().uuidString).mp4")
        try Data(repeating: 1, count: 2048).write(to: file)
        rig.session.uploads.enqueue([
            UploadJob(
                batchID: UUID(), index: 0, file: file, ownsFile: true, fileSize: 2048, mimeType: "video/mp4", title: "Clip",
                settings: UploadSettings(), channelID: "fixture-channel", accountID: creator.id)
        ])
        return file
    }

    private func running(_ rig: DeleteAccountRig, _ transfer: SlowTransfer) async {
        while transfer.sends == 0 { try? await Task.sleep(for: .milliseconds(5)) }
    }

    @Test func anUploadInProgressStandsStillBeforeTheFirstCallAndIsKeptOnFailure() async throws {
        let transfer = SlowTransfer()
        let spy = SpyDeletion(erases: [nil])
        let rig = await DeleteAccountRig(spy, transfer: transfer)
        let file = try enqueue(rig)
        await running(rig, transfer)
        let seen = Seen()
        spy.onErase { seen.set(transfer.cut) }
        await DeleteAccountModel(account: creator, session: rig.session).act()
        #expect(seen.value == 1)
        #expect(FileManager.default.fileExists(atPath: file.path))
        // It goes on after the attempt, because the account still exists.
        while transfer.sends < 2 { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(rig.session.uploads.heldAccounts.isEmpty)
        rig.session.uploads.remove(rig.session.uploads.jobs[0].id)
    }

    @Test func anUploadInProgressIsRemovedOnceTheAccountIsGoneAndCantComeBack() async throws {
        let transfer = SlowTransfer()
        let rig = await DeleteAccountRig(transfer: transfer)
        let file = try enqueue(rig)
        await running(rig, transfer)
        await DeleteAccountModel(account: creator, session: rig.session).act()
        #expect(rig.session.uploads.jobs.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(transfer.sends == 1)
        let late = try enqueue(rig)
        #expect(rig.session.uploads.jobs.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: late.path))
    }

    @Test func anUploadOfTheFirstAccountNeverRunsWhileSomeoneElseSignsIn() async throws {
        let transfer = SlowTransfer()
        let other = StudioAccount(id: "other", email: "amina.yusuf@example.org")
        let accounts = FixtureAccountService(
            signedIn: [creator], signedInAt: Date(timeIntervalSinceNow: -3600), stepUpAccount: other)
        final class Watching: WebAuthenticating {
            let transfer: SlowTransfer
            var running = false
            init(_ transfer: SlowTransfer) { self.transfer = transfer }
            func authenticate(_ request: SignInRequest) async throws -> URL {
                running = transfer.sends > transfer.cut
                return try await FixtureWebAuthenticator().authenticate(request)
            }
        }
        let watching = Watching(transfer)
        let rig = await DeleteAccountRig(accounts: accounts, authenticator: watching, transfer: transfer)
        _ = try enqueue(rig)
        await running(rig, transfer)
        let model = DeleteAccountModel(account: creator, session: rig.session)
        await model.act()
        await model.act()
        #expect(!watching.running)
        #expect(model.end == .otherAccount)
        rig.session.uploads.remove(rig.session.uploads.jobs[0].id)
    }

    private func pick(_ rig: DeleteAccountRig, _ owns: Bool = true) throws -> URL {
        let file = FileManager.default.temporaryDirectory.appending(path: "pick-\(UUID().uuidString).mp4")
        try Data(repeating: 1, count: 64).write(to: file)
        rig.session.composer.add([try #require(PickedVideo.make(file: file, ownsFile: owns))])
        return file
    }

    @Test func whatTheAccountPickedAndNeverSentLeavesTheFormAndTheDisk() async throws {
        let other = StudioAccount(id: "other", email: "amina.yusuf@example.org")
        let rig = await DeleteAccountRig(accounts: FixtureAccountService(signedIn: [creator, other]))
        let copy = try pick(rig)
        let original = try pick(rig, false)
        await rig.session.switchAccount(to: "other")
        let others = try pick(rig)
        await rig.session.switchAccount(to: creator.id)
        await DeleteAccountModel(account: creator, session: rig.session).act()
        #expect(rig.session.account?.id == "other")
        #expect(rig.session.composer.files.map(\.file) == [others])
        #expect(!FileManager.default.fileExists(atPath: copy.path))
        // A picked file on the Mac is the person's own, not a copy.
        #expect(FileManager.default.fileExists(atPath: original.path))
        #expect(FileManager.default.fileExists(atPath: others.path))
        await rig.session.signOut("other")
        #expect(rig.session.composer.files.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: others.path))
    }

    @Test func aDeletionThatStopsKeepsWhatWasPicked() async throws {
        let rig = await DeleteAccountRig(SpyDeletion(erases: [nil]))
        let copy = try pick(rig)
        await DeleteAccountModel(account: creator, session: rig.session).act()
        #expect(rig.session.composer.files.map(\.file) == [copy])
        #expect(FileManager.default.fileExists(atPath: copy.path))
        rig.session.composer.discard(of: creator.id)
    }

    private final class Seen: @unchecked Sendable {
        private let lock = NSLock()
        private var stored = 0
        var value: Int { lock.withLock { stored } }
        func set(_ value: Int) { lock.withLock { stored = value } }
    }
}
