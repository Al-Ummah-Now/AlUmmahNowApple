import AUNCoreBridge
import Foundation

/// Native passkey sign-in and "Add a passkey", shared by Studio and Admin.
///
/// Sign-in starts a normal PKCE sign-in (so the Keychain, multi-account and token code stay one path), sends its
/// code challenge to `/native/passkey/options`, runs the platform sheet, trades the assertion for a code at
/// `/native/passkey/verify`, and completes the sign-in with that code as if the browser had redirected.
@MainActor public struct PasskeyFlow {
    public let accounts: any AccountServicing
    public let service: any PasskeyServicing
    public let authenticator: any PasskeyAuthenticating
    /// The browser sign-in, for re-authentication before adding a passkey.
    public let web: any WebAuthenticating
    public let issuer: URL

    public init(
        accounts: any AccountServicing, service: any PasskeyServicing, authenticator: any PasskeyAuthenticating,
        web: any WebAuthenticating, issuer: URL
    ) {
        self.accounts = accounts
        self.service = service
        self.authenticator = authenticator
        self.web = web
        self.issuer = issuer
    }

    /// Signs in with a passkey and makes the account active.
    public func signIn(_ prompt: SignInPrompt = .standard) async throws -> StudioAccount {
        let request = try await accounts.beginSignIn(prompt)
        guard let pkce = request.pkce else { throw PasskeyError.failed("pkce") }
        let options = try await service.signInOptions(
            issuer: pkce.issuer, clientID: pkce.clientID, codeChallenge: pkce.codeChallenge)
        let assertion = try await authenticator.assert(options)
        let code = try await service.verifySignIn(
            issuer: pkce.issuer, challengeID: options.challengeID, clientID: pkce.clientID, assertion: assertion)
        guard let redirect = pkce.redirect(code: code) else { throw PasskeyError.failed("redirect") }
        return try await accounts.completeSignIn(redirect: redirect)
    }

    /// Adds a passkey to the active account. Throws `PasskeyError.stepUpRequired` when the sign-in is older than
    /// the server allows; then call `reauthenticateAndRegister(accountID:)`.
    public func register(name: String? = nil) async throws -> PasskeyRecord {
        guard let token = try await accounts.accessToken() else { throw PasskeyError.signInRequired }
        let options = try await service.registrationOptions(issuer: issuer, accessToken: token)
        let registration = try await authenticator.register(options)
        return try await service.verifyRegistration(
            issuer: issuer, accessToken: token, challengeID: options.challengeID, registration: registration,
            name: name)
    }

    /// The server wants a sign-in from the last 15 minutes before adding a passkey.
    public static let stepUpWindow = 15 * 60

    public enum StepUpOutcome: Equatable {
        case added(PasskeyRecord)
        /// The person signed in with a different account, which is now active; nothing was added.
        case otherAccount(StudioAccount)
    }

    /// Signs the account in again in the browser sheet (`prompt=login&max_age=900`), then adds the passkey. A second step-up demand right after a
    /// fresh sign-in is reported as a failure instead of looping.
    public func reauthenticateAndRegister(accountID: String, name: String? = nil) async throws -> StepUpOutcome {
        let request = try await accounts.beginSignIn(.stepUp(maxAge: Self.stepUpWindow))
        let redirect = try await web.authenticate(request)
        let account = try await accounts.completeSignIn(redirect: redirect)
        guard account.id == accountID else { return .otherAccount(account) }
        do {
            return .added(try await register(name: name))
        } catch PasskeyError.stepUpRequired {
            throw PasskeyError.failed("step_up_again")
        }
    }
}

/// An in-app message about a passkey action: L10n keys, and the one follow-up it offers.
public struct PasskeyDialog: Identifiable, Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        /// The browser sign-in; `addingAccount` when it came from "Add account".
        case signInAnotherWay(addingAccount: Bool)
        /// Re-authenticate, then add the passkey.
        case signInAgain
    }

    public let id = UUID()
    public var titleKey: String
    public var messageKey: String
    public var values: [String]
    public var action: Action?
    public var isError: Bool

    public init(titleKey: String, messageKey: String, values: [String] = [], action: Action? = nil, isError: Bool = true) {
        self.titleKey = titleKey
        self.messageKey = messageKey
        self.values = values
        self.action = action
        self.isError = isError
    }

    public static func == (lhs: PasskeyDialog, rhs: PasskeyDialog) -> Bool {
        lhs.titleKey == rhs.titleKey && lhs.messageKey == rhs.messageKey && lhs.values == rhs.values
            && lhs.action == rhs.action && lhs.isError == rhs.isError
    }

    public static let added = PasskeyDialog(titleKey: "passkey.add", messageKey: "passkey.added", isError: false)

    public static func otherAccount(_ expected: String) -> PasskeyDialog {
        PasskeyDialog(titleKey: "passkey.add", messageKey: "passkey.otherAccount", values: [expected])
    }

    /// The dialog for a failed passkey sign-in; nil when the person cancelled.
    public static func signInFailure(_ error: any Error, addingAccount: Bool = false) -> PasskeyDialog? {
        let another = Action.signInAnotherWay(addingAccount: addingAccount)
        func dialog(_ key: String, _ action: Action? = another) -> PasskeyDialog {
            PasskeyDialog(titleKey: "passkey.signIn", messageKey: key, action: action)
        }
        if let core = error as? CoreError {
            switch core {
            case .cancelled: return nil
            case .offline: return dialog("passkey.offline", nil)
            default: return dialog("passkey.signInFailed")
            }
        }
        switch error as? PasskeyError ?? .failed(nil) {
        case .cancelled: return nil
        case .noCredential: return dialog("passkey.noCredential")
        case .notAssociated: return dialog("passkey.notAssociated")
        case .rateLimited: return dialog("passkey.rateLimited")
        case .offline: return dialog("passkey.offline", nil)
        default: return dialog("passkey.signInFailed")
        }
    }

    /// The dialog for a failed "Add a passkey"; nil when the person cancelled.
    public static func registerFailure(_ error: any Error) -> PasskeyDialog? {
        func dialog(_ key: String, _ action: Action? = nil) -> PasskeyDialog {
            PasskeyDialog(titleKey: "passkey.add", messageKey: key, action: action)
        }
        if let core = error as? CoreError {
            switch core {
            case .cancelled: return nil
            case .offline: return dialog("passkey.offline")
            case .signInRequired: return dialog("passkey.stale", .signInAgain)
            default: return dialog("passkey.addFailed")
            }
        }
        switch error as? PasskeyError ?? .failed(nil) {
        case .cancelled: return nil
        case .stepUpRequired, .signInRequired: return dialog("passkey.stale", .signInAgain)
        case .alreadyRegistered: return dialog("passkey.exists")
        case .limit: return dialog("passkey.limit")
        case .notAssociated: return dialog("passkey.notAssociated.add")
        case .rateLimited: return dialog("passkey.rateLimited")
        case .offline: return dialog("passkey.offline")
        case .noCredential, .failed: return dialog("passkey.addFailed")
        }
    }
}
