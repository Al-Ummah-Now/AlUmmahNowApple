import AUNCoreBridge
import AuthenticationServices
import Foundation

#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#endif

/// Runs the platform passkey sheet (no browser): passkeys in iCloud Keychain, 1Password or another credential
/// provider, a phone over QR (hybrid) and security keys.
@MainActor public protocol PasskeyAuthenticating {
    func assert(_ options: PasskeyRequestOptions) async throws -> PasskeyAssertion
    func register(_ options: PasskeyCreationOptions) async throws -> PasskeyRegistration
}

/// Presents built requests. The live one runs an ASAuthorizationController; UI tests swap it to stop at this seam,
/// because the system sheet cannot be driven in the simulator.
@MainActor public protocol PasskeyControllerPresenting {
    func perform(_ requests: [ASAuthorizationRequest]) async throws -> ASAuthorization
}

/// `PasskeyAuthenticating` on ASAuthorizationController.
@MainActor
public final class SystemPasskeyAuthenticator: PasskeyAuthenticating {
    private let presenter: any PasskeyControllerPresenting

    public init(presenter: any PasskeyControllerPresenting = AuthorizationControllerPresenter()) {
        self.presenter = presenter
    }

    public func assert(_ options: PasskeyRequestOptions) async throws -> PasskeyAssertion {
        let authorization = try await perform(Self.assertionRequests(options))
        guard let credential = authorization.credential as? any ASAuthorizationPublicKeyCredentialAssertion else {
            throw PasskeyError.failed("credential")
        }
        let attachment: PasskeyAttachment
        if let platform = credential as? ASAuthorizationPlatformPublicKeyCredentialAssertion {
            attachment = platform.attachment == .crossPlatform ? .crossPlatform : .platform
        } else {
            attachment = .crossPlatform
        }
        return PasskeyAssertion(
            credentialID: credential.credentialID, clientDataJSON: credential.rawClientDataJSON,
            authenticatorData: credential.rawAuthenticatorData, signature: credential.signature,
            userHandle: credential.userID, attachment: attachment)
    }

    public func register(_ options: PasskeyCreationOptions) async throws -> PasskeyRegistration {
        let authorization = try await perform(Self.registrationRequests(options))
        guard let credential = authorization.credential as? ASAuthorizationPlatformPublicKeyCredentialRegistration,
            let attestation = credential.rawAttestationObject
        else { throw PasskeyError.failed("credential") }
        let crossPlatform = credential.attachment == .crossPlatform
        return PasskeyRegistration(
            credentialID: credential.credentialID, clientDataJSON: credential.rawClientDataJSON,
            attestationObject: attestation, attachment: crossPlatform ? .crossPlatform : .platform,
            transports: crossPlatform ? ["hybrid"] : ["internal", "hybrid"])
    }

    private func perform(_ requests: [ASAuthorizationRequest]) async throws -> ASAuthorization {
        do {
            return try await presenter.perform(requests)
        } catch let error as PasskeyError {
            throw error
        } catch {
            throw Self.map(error)
        }
    }

    /// One request for the platform (this device, synced password managers, a phone over QR) and one for security
    /// keys, so the sheet offers every kind of passkey.
    public static func assertionRequests(_ options: PasskeyRequestOptions) -> [ASAuthorizationRequest] {
        let preference = verification(options.userVerification)
        let platform = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: options.rpID)
            .createCredentialAssertionRequest(challenge: options.challenge)
        platform.allowedCredentials = options.allowCredentialIDs.map {
            ASAuthorizationPlatformPublicKeyCredentialDescriptor(credentialID: $0)
        }
        platform.userVerificationPreference = preference
        let key = ASAuthorizationSecurityKeyPublicKeyCredentialProvider(relyingPartyIdentifier: options.rpID)
            .createCredentialAssertionRequest(challenge: options.challenge)
        key.allowedCredentials = options.allowCredentialIDs.map {
            ASAuthorizationSecurityKeyPublicKeyCredentialDescriptor(
                credentialID: $0, transports: ASAuthorizationSecurityKeyPublicKeyCredentialDescriptor.Transport.allSupported)
        }
        key.userVerificationPreference = preference
        return [platform, key]
    }

    /// A platform passkey (saved to iCloud Keychain or the person's chosen credential provider).
    public static func registrationRequests(_ options: PasskeyCreationOptions) -> [ASAuthorizationRequest] {
        let request = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: options.rpID)
            .createCredentialRegistrationRequest(
                challenge: options.challenge, name: options.userName, userID: options.userID)
        request.displayName = options.userDisplayName
        request.userVerificationPreference = verification(options.userVerification)
        if #available(iOS 17.4, macOS 14.4, *) {
            request.excludedCredentials = options.excludeCredentialIDs.map {
                ASAuthorizationPlatformPublicKeyCredentialDescriptor(credentialID: $0)
            }
        }
        return [request]
    }

    static func verification(_ value: String?) -> ASAuthorizationPublicKeyCredentialUserVerificationPreference {
        switch value {
        case "required": .required
        case "discouraged": .discouraged
        default: .preferred
        }
    }

    /// Platform errors in passkey terms. Closing the sheet is `cancelled`, which no screen shows.
    nonisolated static func map(_ error: any Error) -> PasskeyError {
        let ns = error as NSError
        guard ns.domain == ASAuthorizationError.errorDomain else { return .failed(nil) }
        switch ns.code {
        case ASAuthorizationError.canceled.rawValue: return .cancelled
        // matchedExcludedCredential (iOS 18, macOS 15): this device already has a passkey for the account.
        case 1006: return .alreadyRegistered
        case ASAuthorizationError.failed.rawValue:
            let text = "\(ns.localizedDescription) \(ns.userInfo)"
            return text.localizedCaseInsensitiveContains("not associated") ? .notAssociated : .failed("platform")
        default: return .failed("platform")
        }
    }
}

/// Runs the requests in an ASAuthorizationController over the key window.
@MainActor
public final class AuthorizationControllerPresenter: NSObject, PasskeyControllerPresenting,
    ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding
{
    private var controller: ASAuthorizationController?
    private var continuation: CheckedContinuation<ASAuthorization, any Error>?

    override public init() {}

    public func perform(_ requests: [ASAuthorizationRequest]) async throws -> ASAuthorization {
        // One sheet at a time: a second tap cancels the first.
        controller?.cancel()
        finish(.failure(PasskeyError.cancelled))
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let controller = ASAuthorizationController(authorizationRequests: requests)
            controller.delegate = self
            controller.presentationContextProvider = self
            self.controller = controller
            controller.performRequests()
        }
    }

    private func finish(_ result: Result<ASAuthorization, any Error>) {
        guard let continuation else { return }
        self.continuation = nil
        controller = nil
        continuation.resume(with: result)
    }

    nonisolated public func authorizationController(
        controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        MainActor.assumeIsolated { finish(.success(authorization)) }
    }

    nonisolated public func authorizationController(
        controller: ASAuthorizationController, didCompleteWithError error: any Error
    ) {
        MainActor.assumeIsolated { finish(.failure(error)) }
    }

    nonisolated public func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        MainActor.assumeIsolated { PresentationAnchor.keyWindow() }
    }
}

/// The window system sheets attach to.
@MainActor enum PresentationAnchor {
    static func keyWindow() -> ASPresentationAnchor {
        #if canImport(UIKit)
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            return scenes.flatMap(\.windows).first(where: \.isKeyWindow) ?? ASPresentationAnchor()
        #else
            return NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first ?? ASPresentationAnchor()
        #endif
    }
}

/// Completes ceremonies at once, for UI tests and previews. `presentsRequests` first builds the real
/// ASAuthorization requests (the seam right before the system sheet) and records how many there were.
@MainActor public final class FixturePasskeyAuthenticator: PasskeyAuthenticating {
    public enum Outcome: String, Sendable { case success, cancel, noCredential }

    public let outcome: Outcome
    public private(set) var presentedRequests: [ASAuthorizationRequest] = []

    public init(outcome: Outcome = .success) { self.outcome = outcome }

    /// The fixture ceremony for `-AUNFixturePasskey` (`cancel` closes the sheet; other values succeed here and are
    /// answered by the fixture server).
    public static func fromLaunchArguments(defaults: UserDefaults = .standard) -> FixturePasskeyAuthenticator {
        FixturePasskeyAuthenticator(outcome: defaults.string(forKey: "AUNFixturePasskey") == "cancel" ? .cancel : .success)
    }

    public func assert(_ options: PasskeyRequestOptions) async throws -> PasskeyAssertion {
        presentedRequests = SystemPasskeyAuthenticator.assertionRequests(options)
        switch outcome {
        case .cancel: throw PasskeyError.cancelled
        case .noCredential: throw PasskeyError.noCredential
        case .success:
            return PasskeyAssertion(
                credentialID: Data("fixture-credential".utf8), clientDataJSON: Data("{}".utf8),
                authenticatorData: Data([1, 2, 3]), signature: Data([4, 5, 6]), userHandle: Data("fixture".utf8),
                attachment: .platform)
        }
    }

    public func register(_ options: PasskeyCreationOptions) async throws -> PasskeyRegistration {
        presentedRequests = SystemPasskeyAuthenticator.registrationRequests(options)
        if outcome == .cancel { throw PasskeyError.cancelled }
        return PasskeyRegistration(
            credentialID: Data("fixture-credential".utf8), clientDataJSON: Data("{}".utf8),
            attestationObject: Data([7, 8, 9]), attachment: .platform, transports: ["internal", "hybrid"])
    }
}
