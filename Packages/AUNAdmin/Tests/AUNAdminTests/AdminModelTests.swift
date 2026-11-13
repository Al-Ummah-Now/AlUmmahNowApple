import AUNCoreBridge
import AUNDesign
import AUNStudio
import Foundation
import Testing

@testable import AUNAdmin

/// A clock the tests move by hand.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_800_000_000)
    var now: Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value = value.addingTimeInterval(seconds) } }
}

@MainActor
struct AdminSessionTests {
    let clock = TestClock()

    func session(role: FixtureReviewService.Role = .reviewer, signedIn: Bool = true, passcode: Bool = true) -> AdminSession {
        let review = FixtureReviewService(role: role)
        let account = StudioAccount(id: "fx-reviewer", displayName: "Fixture Reviewer")
        let services = AdminServices(
            accounts: FixtureAccountService(signedIn: signedIn ? [account] : []), review: review, push: review)
        let clock = clock
        return AdminSession(
            services: services, authenticator: FixtureWebAuthenticator(), lock: FixtureDeviceUnlock(passcode: passcode),
            installID: "install-test-1", network: NetworkMonitor(forcedOffline: false), now: { clock.now })
    }

    @Test func opensLockedAndUnlocksIntoTheQueue() async {
        let session = session()
        await session.start()
        #expect(session.phase == .locked)
        await session.unlock(reason: "test")
        #expect(session.phase == .ready)
        #expect(session.profile?.isReviewer == true)
        #expect(session.isSenior == false)
    }

    @Test func someoneWithoutAStaffRoleIsTurnedAway() async {
        let session = session(role: .viewer)
        await session.start()
        await session.unlock(reason: "test")
        #expect(session.phase == .notStaff)
    }

    @Test func noPasscodeMeansNoSignIn() async {
        let session = session(signedIn: false, passcode: false)
        await session.start()
        #expect(session.phase == .signedOut)
        await session.signIn()
        #expect(session.phase == .signedOut)
        #expect(session.notice == "admin.signIn.noPasscode")
    }

    @Test func locksAgainOnlyAfterFiveMinutesInTheBackground() async {
        let session = session()
        await session.start()
        await session.unlock(reason: "test")
        session.enteredBackground()
        clock.advance(4 * 60)
        session.becameActive()
        #expect(session.phase == .ready)
        session.enteredBackground()
        clock.advance(5 * 60 + 1)
        session.becameActive()
        #expect(session.phase == .locked)
    }

    @Test func aSignInCountsAsRecentForFifteenMinutes() async {
        let session = session(signedIn: false)
        await session.start()
        await session.signIn()
        #expect(session.phase == .ready)
        #expect(session.stepUpIsFresh)
        clock.advance(15 * 60 + 1)
        #expect(!session.stepUpIsFresh)
        #expect(await session.requireRecentSignIn())
        #expect(session.stepUpIsFresh)
    }

    @Test func signOutRemovesThePushDevice() async throws {
        let review = FixtureReviewService()
        try await review.register(installID: "install-test-1", token: "ab", platform: "ios", locale: "en", appVersion: "1")
        let account = StudioAccount(id: "fx-reviewer")
        let session = AdminSession(
            services: AdminServices(accounts: FixtureAccountService(signedIn: [account]), review: review, push: review),
            authenticator: FixtureWebAuthenticator(), lock: FixtureDeviceUnlock(), installID: "install-test-1",
            network: NetworkMonitor(forcedOffline: false))
        await session.start()
        await session.signOut()
        #expect(session.phase == .signedOut)
        #expect(await review.registeredInstalls.isEmpty)
    }
}

@MainActor
struct QueueModelTests {
    @Test func actionNeededIsByDeadlineThenRiskAndSeniorsSeeEscalationsFirst() {
        let now = Date()
        let a = ReviewItem(id: "a", subjectID: "1", risk: 0.2, slaDueAt: now.addingTimeInterval(600))
        let b = ReviewItem(id: "b", subjectID: "2", risk: 0.9, slaDueAt: now.addingTimeInterval(600))
        let c = ReviewItem(id: "c", subjectID: "3", risk: 0.1, slaDueAt: now.addingTimeInterval(60))
        let e = ReviewItem(id: "e", subjectID: "4", risk: 0.1, escalate: true, slaDueAt: now.addingTimeInterval(900))
        #expect(QueueModel.sorted([a, b, c, e], tab: .actionNeeded, senior: false).map(\.id) == ["c", "b", "a", "e"])
        #expect(QueueModel.sorted([a, b, c, e], tab: .actionNeeded, senior: true).map(\.id) == ["e", "c", "b", "a"])
    }

    @Test func searchSuggestionsOpenWithResultsAndNarrow() async {
        let model = QueueModel(service: FixtureReviewService(), senior: false)
        await model.load()
        #expect(!model.suggestions(for: "").isEmpty)
        #expect(model.suggestions(for: "hope") == ["Hope Relief"])
    }

    @Test func offlineKeepsTheTextOnlyList() async {
        let service = FixtureReviewService()
        let model = QueueModel(service: service, senior: false)
        await model.load()
        let count = model.items.count
        await service.setOffline(true)
        await model.load()
        #expect(model.isOffline)
        #expect(model.items.count == count)
    }
}

@MainActor
struct ReviewModelTests {
    let clock = TestClock()

    func make(_ id: String, offline: Bool = false, role: FixtureReviewService.Role = .reviewer)
        -> (ReviewModel, ToastCenter, FixtureReviewService, Box)
    {
        let review = FixtureReviewService(role: role)
        let account = StudioAccount(id: "fx-reviewer")
        let session = AdminSession(
            services: AdminServices(accounts: FixtureAccountService(signedIn: [account]), review: review, push: review),
            authenticator: FixtureWebAuthenticator(), lock: FixtureDeviceUnlock(), installID: "install-test-1",
            network: NetworkMonitor(forcedOffline: offline))
        let toasts = ToastCenter()
        let box = Box()
        let clock = clock
        let model = ReviewModel(
            id: id, service: review, session: session, toasts: toasts, l10n: L10n(.en), now: { clock.now }
        ) { box.changed.append($0) }
        return (model, toasts, review, box)
    }

    final class Box { var changed: [ReviewItem] = [] }

    @Test func approveTakesEffectAndOffersUndo() async {
        let (model, toasts, _, box) = make("fx-risk")
        await model.open()
        await model.decide(.approve)
        #expect(model.item?.status == "approved")
        #expect(box.changed.last?.status == "approved")
        #expect(toasts.toast?.actionTitle == "Undo")
        await toasts.perform()
        #expect(model.item?.isOpen == true)
        #expect(toasts.toast?.text == "Reversed. The creator is told.")
    }

    @Test func aConflictNamesWhoDecided() async {
        let (model, _, _, _) = make("fx-conflict")
        await model.open()
        await model.decide(.approve)
        #expect(model.message?.hasPrefix("Already approved by Amina") == true)
    }

    @Test func offlineNothingIsSentOrQueued() async {
        let (model, toasts, _, box) = make("fx-risk", offline: true)
        await model.open()
        await model.decide(.approve)
        #expect(model.message == "You're offline. Decisions need a connection.")
        #expect(box.changed.isEmpty)
        #expect(toasts.toast == nil)
        #expect(model.item?.isOpen == true)
    }

    @Test func showIsAuditedAndBlursAgainWhenIdleOrHidden() async {
        let (model, _, review, _) = make("fx-nsfw")
        await model.open()
        #expect(model.isBlurred)
        await model.reveal()
        #expect(!model.isBlurred)
        #expect(await review.reveals == ["fx-nsfw:item"])
        #expect(!model.idleExpired(at: clock.now.addingTimeInterval(59)))
        #expect(model.idleExpired(at: clock.now.addingTimeInterval(60)))
        model.hide()
        #expect(model.isBlurred)
        model.close()
        #expect(model.isBlurred)
    }

    @Test func openingClaimsTheItem() async throws {
        let (model, _, review, _) = make("fx-risk")
        await model.open()
        try await Task.sleep(for: .milliseconds(200))
        #expect(await review.claims.contains("fx-risk"))
        model.close()
    }

    @Test func conflictTextIsLocalized() {
        let at = Date(timeIntervalSince1970: 1_000)
        let now = at.addingTimeInterval(20)
        let en = ReviewModel.conflictText(decision: "approve", name: "Amina", at: at, now: now, l10n: L10n(.en))
        #expect(en.hasPrefix("Already approved by Amina"))
        let ar = ReviewModel.conflictText(decision: "reject", name: "أمينة", at: at, now: now, l10n: L10n(.ar))
        // Arabic formatting wraps each argument in direction isolates (U+2068 … U+2069).
        let plain = ar.unicodeScalars.filter { $0 != "\u{2068}" && $0 != "\u{2069}" }.map(String.init).joined()
        #expect(plain.hasPrefix("رفضه أمينة"), "\(ar)")
        #expect(
            ReviewModel.conflictText(decision: nil, name: nil, at: nil, now: now, l10n: L10n(.en))
                == "Someone else already decided this item.")
    }

    @Test func framesPutFlaggedFirst() {
        let findings = [
            ReviewFinding(id: "1", source: "frame", category: "gore", score: 0.4, atMs: 9000, mediaKey: "k9"),
            ReviewFinding(id: "2", source: "frame", category: "sexual", score: 0.9, atMs: 3000, mediaKey: "k3"),
            ReviewFinding(id: "3", source: "metadata", category: "spam", score: 0.5),
        ]
        let manifest = [ReviewFrame(key: "k0", atMs: 0, flagged: false), ReviewFrame(key: "k3", atMs: 3000, flagged: false)]
        let frames = ReviewDetail.frames(findings: findings, manifest: manifest)
        #expect(frames.map(\.key) == ["k3", "k9", "k0"])
        #expect(frames.map(\.flagged) == [true, true, false])
    }
}
