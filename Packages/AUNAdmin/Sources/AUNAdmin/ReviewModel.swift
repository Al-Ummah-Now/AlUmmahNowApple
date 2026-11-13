import AUNCoreBridge
import AUNDesign
import Foundation
import Observation

/// One open review: claim and renew, reveal and re-blur, decide and undo (wiki AUN-ADMIN-NATIVE, phase 1).
@MainActor @Observable
public final class ReviewModel {
    public enum State: Equatable { case loading, loaded, failed }

    public let id: String
    public private(set) var state: State = .loading
    public private(set) var detail: ReviewDetail?
    /// The item is shown unblurred after an audited "Show". Never carried to another item.
    public private(set) var revealed = false
    public private(set) var isDeciding = false
    /// A conflict or refusal to show above the buttons, already localized.
    public private(set) var message: String?
    public private(set) var claimedByOther: String?

    let service: any ReviewServicing
    let session: AdminSession
    let toasts: ToastCenter
    let l10n: L10n
    let onChange: (ReviewItem) -> Void
    private let now: () -> Date
    private var claimTask: Task<Void, Never>?
    private var idleTask: Task<Void, Never>?
    private var lastInteraction = Date()

    /// The claim lasts 3 minutes on the server; it is renewed every minute while the item is open.
    static let claimRenewal: Duration = .seconds(60)
    /// A revealed item blurs again after 60 s without interaction.
    static let idleReblur: TimeInterval = 60

    public init(
        id: String, service: any ReviewServicing, session: AdminSession, toasts: ToastCenter, l10n: L10n,
        now: @escaping () -> Date = Date.init, onChange: @escaping (ReviewItem) -> Void
    ) {
        self.id = id
        self.service = service
        self.session = session
        self.toasts = toasts
        self.l10n = l10n
        self.now = now
        self.onChange = onChange
    }

    public var item: ReviewItem? { detail?.item }
    public var isSensitive: Bool { item?.isSensitive ?? false }
    /// Blurred: sensitive and not revealed.
    public var isBlurred: Bool { isSensitive && !revealed }

    public func open() async {
        state = .loading
        do {
            detail = try await service.detail(id)
            state = .loaded
            startClaim()
        } catch {
            AUNLog.admin.error("Review failed to load: \(error)")
            state = .failed
        }
    }

    /// Leaving the item: re-blur, stop renewing the claim.
    public func close() {
        claimTask?.cancel()
        idleTask?.cancel()
        revealed = false
    }

    private func startClaim() {
        guard item?.isOpen == true else { return }
        claimTask?.cancel()
        claimTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                do {
                    try await self.service.claim(self.id)
                    self.claimedByOther = nil
                } catch ReviewError.claimedByOther(let name) {
                    self.claimedByOther = name ?? ""
                } catch {
                    AUNLog.admin.info("Claim renewal failed: \(error)")
                }
                try? await Task.sleep(for: Self.claimRenewal)
            }
        }
    }

    // MARK: Reveal

    /// "Show": audited per item. A minor item also needs a sign-in within 15 minutes (AD13).
    public func reveal() async {
        guard let item, isBlurred else { return }
        if item.minor, !(await session.requireRecentSignIn()) { return }
        do {
            try await service.reveal(id, target: "item")
            revealed = true
            interacted()
            startIdleTimer()
        } catch ReviewError.stepUpRequired {
            if await session.requireRecentSignIn(force: true) { await reveal() }
        } catch {
            message = l10n("admin.reveal.failed")
        }
    }

    public func hide() {
        revealed = false
        idleTask?.cancel()
    }

    public func interacted() { lastInteraction = now() }

    private func startIdleTimer() {
        idleTask?.cancel()
        idleTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self, !Task.isCancelled else { return }
                if self.idleExpired(at: self.now()) {
                    self.hide()
                    return
                }
            }
        }
    }

    func idleExpired(at date: Date) -> Bool { revealed && date.timeIntervalSince(lastInteraction) >= Self.idleReblur }

    // MARK: Decide

    /// Takes effect at once; a 10 s undo toast reverses it (the server tells the creator).
    public func decide(_ decision: ReviewDecision, reason: ReviewReason? = nil, note: String? = nil) async {
        guard let item, !isDeciding else { return }
        guard !session.isOffline else {
            message = l10n("admin.offline.decide")
            return
        }
        if decision == .approve, item.escalate, !(await session.requireRecentSignIn()) { return }
        isDeciding = true
        defer { isDeciding = false }
        message = nil
        do {
            let result = try await service.decide(id, decision, reason: reason, note: note, version: item.version)
            detail?.item = result.item
            claimTask?.cancel()
            onChange(result.item)
            offerUndo(decision, title: result.item.title ?? item.title ?? "")
        } catch ReviewError.stepUpRequired {
            if await session.requireRecentSignIn(force: true) {
                isDeciding = false
                await decide(decision, reason: reason, note: note)
            }
        } catch ReviewError.alreadyDecided(let done, let name, let at) {
            message = Self.conflictText(decision: done, name: name, at: at, now: now(), l10n: l10n)
            await open()
            if let current = detail?.item { onChange(current) }
        } catch CoreError.offline {
            message = l10n("admin.offline.decide")
        } catch {
            AUNLog.admin.error("Decision failed: \(error)")
            message = l10n("admin.decision.failed")
        }
    }

    private func offerUndo(_ decision: ReviewDecision, title: String) {
        let text = l10n("admin.done.\(decision.rawValue)", title)
        guard decision != .escalate else {
            toasts.show(text)
            return
        }
        toasts.show(text, actionTitle: l10n("admin.undo")) { [weak self] in await self?.undo() }
    }

    public func undo() async {
        do {
            let result = try await service.decide(id, .undo, reason: nil, note: nil, version: item?.version)
            detail?.item = result.item
            onChange(result.item)
            startClaim()
            toasts.show(l10n("admin.undone"))
        } catch ReviewError.undoExpired {
            toasts.show(l10n("admin.undo.expired"), isError: true)
        } catch {
            toasts.show(l10n("admin.undo.failed"), isError: true)
        }
    }

    /// "Already approved by Amina 20 s ago".
    static func conflictText(decision: String?, name: String?, at: Date?, now: Date, l10n: L10n) -> String {
        guard let decision, let name, !name.isEmpty else { return l10n("admin.conflict.generic") }
        let verb = ["approve", "reject", "escalate", "request_changes"].contains(decision) ? decision : "generic"
        let when: String
        if let at {
            let formatter = RelativeDateTimeFormatter()
            formatter.locale = l10n.language.locale
            formatter.unitsStyle = .short
            when = formatter.localizedString(for: at, relativeTo: now)
        } else {
            when = ""
        }
        return l10n("admin.conflict.\(verb)", name, when).trimmingCharacters(in: .whitespaces)
    }
}
