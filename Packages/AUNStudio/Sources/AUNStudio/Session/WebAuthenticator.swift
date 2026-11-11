import AUNCoreBridge
import AuthenticationServices
import Foundation

#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#endif

/// Opens the auth server's sign-in page and returns the redirect URL.
@MainActor public protocol WebAuthenticating {
    func authenticate(_ request: SignInRequest) async throws -> URL
}

/// The system web authentication session (ASWebAuthenticationSession).
///
/// It is ephemeral: no cookies are shared with Safari, so "Add account" always shows the form, and after sign-out the
/// next sign-in can never come back silently as the previous account.
@MainActor
public final class SystemWebAuthenticator: NSObject, WebAuthenticating,
    ASWebAuthenticationPresentationContextProviding
{
    private var session: ASWebAuthenticationSession?

    override public init() {}

    public func authenticate(_ request: SignInRequest) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: request.url, callbackURLScheme: request.callbackScheme) {
                url, error in
                if let url {
                    continuation.resume(returning: url)
                } else if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                    continuation.resume(throwing: CoreError.cancelled)
                } else {
                    continuation.resume(throwing: error ?? CoreError.signInRequired)
                }
            }
            session.prefersEphemeralWebBrowserSession = true
            session.presentationContextProvider = self
            self.session = session
            if !session.start() { continuation.resume(throwing: CoreError.signInRequired) }
        }
    }

    nonisolated public func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            #if canImport(UIKit)
                let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                return scenes.flatMap(\.windows).first(where: \.isKeyWindow) ?? ASPresentationAnchor()
            #else
                return NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first ?? ASPresentationAnchor()
            #endif
        }
    }
}

/// Completes sign-in at once, for UI tests and previews.
@MainActor public struct FixtureWebAuthenticator: WebAuthenticating {
    public init() {}
    public func authenticate(_ request: SignInRequest) async throws -> URL {
        URL(string: "\(request.callbackScheme)://auth/callback?code=fixture&state=fixture")!
    }
}
