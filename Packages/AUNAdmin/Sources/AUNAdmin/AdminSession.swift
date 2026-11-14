import AUNCoreBridge
import AUNStudio
import Foundation
import Observation

/// Sign-in, the staff check, the device lock and step-up (wiki AUN-ADMIN-NATIVE, Auth).
@MainActor @Observable
public final class AdminSession {
    public enum Phase: Equatable {
        case loading, signedOut, locked, checking, notStaff, ready
        /// The staff check could not run (offline or a server error): retry.
        case unverified
    }

    public private(set) var phase: Phase = .loading {
        didSet { if phase != oldValue { LaunchClock.phase(phase) } }
    }
    public private(set) var account: StudioAccount?
    public private(set) var profile: StaffProfile?
    /// The review queue, loaded with the staff check so the screen after it opens with its rows. Loading it from the
    /// shell instead cost a full main-thread round trip behind the shell's first layout, seconds on a busy CI runner.
    public private(set) var queue: QueueModel?
    public private(set) var isSigningIn = false
    /// An L10n key to show on the current screen.
    public var notice: String?
    /// The last sign-in or step-up; high-risk actions need one within 15 minutes.
    public private(set) var signedInAt: Date?

    public let services: AdminServices
    public let installID: String
    public let network: NetworkMonitor
    let lock: any DeviceUnlocking
    let policy = LockPolicy()
    private let authenticator: any WebAuthenticating
    private let now: () -> Date
    private var backgroundedAt: Date?

    public init(
        services: AdminServices, authenticator: any WebAuthenticating, lock: any DeviceUnlocking,
        installID: String, network: NetworkMonitor, now: @escaping () -> Date = Date.init
    ) {
        self.services = services
        self.network = network
        self.authenticator = authenticator
        self.lock = lock
        self.installID = installID
        self.now = now
        LaunchClock.mark("session created")
    }

    public var isSenior: Bool { profile?.isSeniorReviewer ?? false }
    /// No decisions offline (AD8).
    public var isOffline: Bool { !network.isOnline }

    public func start() async {
        LaunchClock.mark("start")
        do {
            account = try await services.accounts.activeAccount()
            LaunchClock.mark("account read")
        } catch {
            AUNLog.admin.error("Reading the account failed: \(error)")
        }
        // Always locked on open: the device unlock comes before anything is shown.
        phase = account == nil ? .signedOut : .locked
    }

    // MARK: Lock

    public func unlock(reason: String) async {
        guard phase == .locked else { return }
        guard await lock.unlock(reason: reason) else {
            notice = "admin.lock.failed"
            return
        }
        notice = nil
        if profile == nil { await checkStaff() } else { phase = .ready }
    }

    public func enteredBackground() { backgroundedAt = now() }

    public func becameActive() {
        defer { backgroundedAt = nil }
        guard [.ready, .notStaff, .unverified].contains(phase) else { return }
        if policy.needsUnlock(backgroundedAt: backgroundedAt, now: now()) { phase = .locked }
    }

    // MARK: Sign-in

    public func signIn() async {
        guard !isSigningIn else { return }
        guard lock.hasPasscode() else {
            notice = "admin.signIn.noPasscode"
            return
        }
        isSigningIn = true
        defer { isSigningIn = false }
        do {
            let request = try await services.accounts.beginSignIn(.standard)
            let redirect = try await authenticator.authenticate(request)
            account = try await services.accounts.completeSignIn(redirect: redirect)
            signedInAt = now()
            notice = nil
            await checkStaff()
        } catch {
            if (error as? CoreError) != .cancelled { notice = "admin.signIn.failed" }
            AUNLog.admin.error("Sign-in failed: \(error)")
        }
    }

    /// The server's answer to "is this person staff, and which role": `GET /api/me`, on every launch.
    public func checkStaff() async {
        phase = .checking
        do {
            profile = try await services.review.profile()
            let queue = QueueModel(service: services.review, senior: isSenior)
            await queue.load()
            self.queue = queue
            phase = .ready
        } catch ReviewError.notStaff {
            profile = nil
            phase = .notStaff
        } catch CoreError.signInRequired {
            await signOut()
            notice = "admin.signIn.expired"
        } catch {
            AUNLog.admin.error("Staff check failed: \(error)")
            phase = .unverified
        }
    }

    /// Signs out here, removes this device from push and revokes the refresh token.
    public func signOut() async {
        try? await services.push.unregister(installID: installID)
        if let id = account?.id {
            do { try await services.accounts.signOut(id) } catch { AUNLog.admin.error("Sign-out failed: \(error)") }
        }
        account = nil
        profile = nil
        queue = nil
        signedInAt = nil
        phase = .signedOut
    }

    // MARK: Step-up

    public var stepUpIsFresh: Bool { policy.stepUpIsFresh(signedInAt, now: now()) }

    /// A sign-in within 15 minutes for revealing a minor item and approving an escalated one (AD5). Reopens the
    /// sign-in sheet with `prompt=login&max_age=900` when the last one is older; the server checks `auth_time`.
    public func requireRecentSignIn(force: Bool = false) async -> Bool {
        if !force, stepUpIsFresh { return true }
        guard let current = account else { return false }
        do {
            let request = try await services.accounts.beginSignIn(.stepUp(maxAge: Int(policy.stepUpWindow)))
            let redirect = try await authenticator.authenticate(request)
            let signed = try await services.accounts.completeSignIn(redirect: redirect)
            guard signed.id == current.id else {
                // Someone else signed in on the sheet: keep the reviewer, drop the other account.
                try? await services.accounts.signOut(signed.id)
                _ = try? await services.accounts.switchAccount(to: current.id)
                notice = "admin.stepUp.otherAccount"
                return false
            }
            signedInAt = now()
            return true
        } catch {
            if (error as? CoreError) != .cancelled { notice = "admin.stepUp.failed" }
            return false
        }
    }
}
