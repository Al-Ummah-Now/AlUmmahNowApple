import Foundation
import Testing

@testable import AUNCoreBridge

struct Base64URLTests {
    @Test func encodesWithoutPaddingOrUnsafeCharacters() {
        #expect(Base64URL.encode(Data([0xfb, 0xff, 0xfe])) == "-__-")
        #expect(Base64URL.encode(Data("ab".utf8)) == "YWI")
        #expect(Base64URL.encode(Data()) == "")
    }

    @Test func decodesPaddedUnpaddedAndRoundTrips() {
        #expect(Base64URL.decode("YWI") == Data("ab".utf8))
        #expect(Base64URL.decode("YWI=") == Data("ab".utf8))
        #expect(Base64URL.decode("-__-") == Data([0xfb, 0xff, 0xfe]))
        let bytes = Data((0..<255).map { UInt8($0) })
        #expect(Base64URL.decode(Base64URL.encode(bytes)) == bytes)
    }

    @Test func rejectsImpossibleLengths() {
        #expect(Base64URL.decode("A") == nil)
        #expect(Base64URL.decode("!!!!") == nil)
    }
}

struct PKCESignInTests {
    private let authorize = URL(
        string: "https://auth.qa.alummahnow.net/authorize?client_id=c1&redirect_uri=alummahnow-studio%3A%2F%2Fauth%2Fcallback"
            + "&response_type=code&state=s1&code_challenge=ch1&code_challenge_method=S256&scope=openid")!

    @Test func readsThePKCEValuesOfTheAuthorizeURL() throws {
        let pkce = try #require(SignInRequest(url: authorize, callbackScheme: "alummahnow-studio").pkce)
        #expect(pkce.issuer.absoluteString == "https://auth.qa.alummahnow.net")
        #expect(pkce.clientID == "c1")
        #expect(pkce.codeChallenge == "ch1")
        #expect(pkce.state == "s1")
        #expect(pkce.redirectURI == "alummahnow-studio://auth/callback")
    }

    @Test func buildsTheRedirectTheBrowserWouldHaveReturned() throws {
        let pkce = try #require(SignInRequest(url: authorize, callbackScheme: "alummahnow-studio").pkce)
        let redirect = try #require(pkce.redirect(code: "code/1+2"))
        let parts = try #require(URLComponents(url: redirect, resolvingAgainstBaseURL: false))
        #expect(parts.scheme == "alummahnow-studio")
        #expect(parts.host == "auth")
        #expect(parts.path == "/callback")
        #expect(parts.queryItems?.first { $0.name == "code" }?.value == "code/1+2")
        #expect(parts.queryItems?.first { $0.name == "state" }?.value == "s1")
    }

    @Test func refusesAPlainChallengeOrMissingValues() {
        let plain = URL(string: authorize.absoluteString.replacingOccurrences(of: "S256", with: "plain"))!
        #expect(SignInRequest(url: plain, callbackScheme: "x").pkce == nil)
        let noState = URL(string: authorize.absoluteString.replacingOccurrences(of: "&state=s1", with: ""))!
        #expect(SignInRequest(url: noState, callbackScheme: "x").pkce == nil)
    }

    @Test func theFixtureSignInHasPKCEValues() {
        #expect(SignInRequest(url: FixtureAccountService.authorizeURL, callbackScheme: "x").pkce?.state == "fixture-state")
    }
}

struct PasskeyErrorMappingTests {
    @Test func mapsServerCodes() {
        #expect(PasskeyError.from(status: 401, code: "step_up_required", retryAfter: nil) == .stepUpRequired)
        #expect(PasskeyError.from(status: 400, code: "unknown_credential", retryAfter: nil) == .noCredential)
        #expect(PasskeyError.from(status: 404, code: "credential_not_found", retryAfter: nil) == .noCredential)
        #expect(PasskeyError.from(status: 409, code: "exists", retryAfter: nil) == .alreadyRegistered)
        #expect(PasskeyError.from(status: 403, code: "limit", retryAfter: nil) == .limit)
        #expect(PasskeyError.from(status: 429, code: "rate_limited", retryAfter: "30") == .rateLimited(retryAfter: 30))
        #expect(PasskeyError.from(status: 429, code: nil, retryAfter: "soon") == .rateLimited(retryAfter: nil))
        #expect(PasskeyError.from(status: 401, code: "invalid_token", retryAfter: nil) == .signInRequired)
        #expect(PasskeyError.from(status: 400, code: "invalid_request", retryAfter: nil) == .failed("invalid_request"))
        #expect(PasskeyError.from(status: 500, code: nil, retryAfter: nil) == .failed(nil))
    }
}

struct NativePasskeyServiceTests {
    private let issuer = URL(string: "https://auth.qa.alummahnow.net")!

    private func json(_ request: URLRequest) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: StubURLProtocol.body(of: request)) as? [String: Any])
    }

    private func reply(_ status: Int, _ body: String, headers: [String: String] = [:]) -> (Int, [String: String], Data) {
        (status, headers.merging(["Content-Type": "application/json"]) { a, _ in a }, Data(body.utf8))
    }

    @Test func signInOptionsSendTheCodeChallengeAndMapTheOptions() async throws {
        let service = NativePasskeyService(
            session: StubURLProtocol.session { request in
                #expect(request.httpMethod == "POST")
                #expect(request.url?.absoluteString == "https://auth.qa.alummahnow.net/native/passkey/options")
                #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
                let body = try json(request)
                #expect(body["client_id"] as? String == "c1")
                #expect(body["code_challenge"] as? String == "ch1")
                #expect(body["code_challenge_method"] as? String == "S256")
                return reply(
                    200,
                    """
                    {"challenge_id":"k1","publicKey":{"challenge":"YWJj","rpId":"qa.alummahnow.net","timeout":60000,
                     "userVerification":"required","allowCredentials":[{"id":"-__-","type":"public-key"}]}}
                    """)
            })
        let options = try await service.signInOptions(issuer: issuer, clientID: "c1", codeChallenge: "ch1")
        #expect(options.challengeID == "k1")
        #expect(options.challenge == Data("abc".utf8))
        #expect(options.rpID == "qa.alummahnow.net")
        #expect(options.allowCredentialIDs == [Data([0xfb, 0xff, 0xfe])])
        #expect(options.userVerification == "required")
        #expect(options.timeout == 60)
    }

    @Test func verifySendsAnAuthenticationResponseJSONAndReturnsTheCode() async throws {
        let assertion = PasskeyAssertion(
            credentialID: Data([0xfb, 0xff]), clientDataJSON: Data("{}".utf8), authenticatorData: Data([1]),
            signature: Data([2]), userHandle: Data("u".utf8), attachment: .crossPlatform)
        let service = NativePasskeyService(
            session: StubURLProtocol.session { request in
                #expect(request.url?.path == "/native/passkey/verify")
                let body = try json(request)
                #expect(body["challenge_id"] as? String == "k1")
                #expect(body["client_id"] as? String == "c1")
                let credential = try #require(body["credential"] as? [String: Any])
                #expect(credential["id"] as? String == "-_8")
                #expect(credential["rawId"] as? String == "-_8")
                #expect(credential["type"] as? String == "public-key")
                #expect(credential["authenticatorAttachment"] as? String == "cross-platform")
                let response = try #require(credential["response"] as? [String: Any])
                #expect(response["clientDataJSON"] as? String == "e30")
                #expect(response["authenticatorData"] as? String == "AQ")
                #expect(response["signature"] as? String == "Ag")
                #expect(response["userHandle"] as? String == "dQ")
                return reply(200, #"{"code":"the-code"}"#)
            })
        let code = try await service.verifySignIn(
            issuer: issuer, challengeID: "k1", clientID: "c1", assertion: assertion)
        #expect(code == "the-code")
    }

    @Test func registrationOptionsUseTheBearerTokenAndMapStepUp() async throws {
        let service = NativePasskeyService(
            session: StubURLProtocol.session { request in
                #expect(request.url?.path == "/native/passkey/register/options")
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer t1")
                return reply(401, #"{"error":"step_up_required","error_description":"sign in again"}"#)
            })
        await #expect(throws: PasskeyError.stepUpRequired) {
            _ = try await service.registrationOptions(issuer: issuer, accessToken: "t1")
        }
    }

    @Test func registrationOptionsMapTheCreationOptions() async throws {
        let service = NativePasskeyService(
            session: StubURLProtocol.session { _ in
                reply(
                    200,
                    """
                    {"challenge_id":"k2","publicKey":{"challenge":"YWJj","rp":{"id":"alummahnow.net","name":"Al Ummah Now"},
                     "user":{"id":"dXNlcg","name":"a@example.org","displayName":"A"},"attestation":"none",
                     "excludeCredentials":[{"id":"AQ","type":"public-key"}],
                     "authenticatorSelection":{"residentKey":"required","userVerification":"preferred"}}}
                    """)
            })
        let options = try await service.registrationOptions(issuer: issuer, accessToken: "t1")
        #expect(options.challengeID == "k2")
        #expect(options.rpID == "alummahnow.net")
        #expect(options.rpName == "Al Ummah Now")
        #expect(options.userID == Data("user".utf8))
        #expect(options.userName == "a@example.org")
        #expect(options.userDisplayName == "A")
        #expect(options.excludeCredentialIDs == [Data([1])])
        #expect(options.userVerification == "preferred")
    }

    @Test func registerVerifySendsARegistrationResponseJSONAndMapsTheRecord() async throws {
        let registration = PasskeyRegistration(
            credentialID: Data([1]), clientDataJSON: Data("{}".utf8), attestationObject: Data([3]),
            attachment: .platform, transports: ["internal", "hybrid"])
        let service = NativePasskeyService(
            session: StubURLProtocol.session { request in
                #expect(request.url?.path == "/native/passkey/register/verify")
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer t1")
                let body = try json(request)
                #expect(body["challenge_id"] as? String == "k2")
                #expect(body["name"] as? String == "My iPhone")
                let credential = try #require(body["credential"] as? [String: Any])
                #expect(credential["authenticatorAttachment"] as? String == "platform")
                let response = try #require(credential["response"] as? [String: Any])
                #expect(response["attestationObject"] as? String == "Aw")
                #expect(response["transports"] as? [String] == ["internal", "hybrid"])
                return reply(200, #"{"id":"p1","name":"My iPhone","created_at":"2026-11-13T10:00:00Z"}"#)
            })
        let record = try await service.verifyRegistration(
            issuer: issuer, accessToken: "t1", challengeID: "k2", registration: registration, name: "My iPhone")
        #expect(record == PasskeyRecord(id: "p1", name: "My iPhone", createdAt: "2026-11-13T10:00:00Z"))
    }

    @Test func tooManyTriesCarryRetryAfter() async {
        let service = NativePasskeyService(
            session: StubURLProtocol.session { _ in
                reply(429, #"{"error":"rate_limited"}"#, headers: ["Retry-After": "42"])
            })
        await #expect(throws: PasskeyError.rateLimited(retryAfter: 42)) {
            _ = try await service.signInOptions(issuer: issuer, clientID: "c1", codeChallenge: "ch1")
        }
    }

    @Test func noAccountForThePasskey() async {
        let service = NativePasskeyService(
            session: StubURLProtocol.session { _ in reply(400, #"{"error":"unknown_credential"}"#) })
        let assertion = PasskeyAssertion(
            credentialID: Data([1]), clientDataJSON: Data(), authenticatorData: Data(), signature: Data())
        await #expect(throws: PasskeyError.noCredential) {
            _ = try await service.verifySignIn(issuer: issuer, challengeID: "k", clientID: "c", assertion: assertion)
        }
    }

    @Test func offlineAndBadBodies() async {
        let offline = NativePasskeyService(session: StubURLProtocol.session { _ in throw URLError(.notConnectedToInternet) })
        await #expect(throws: PasskeyError.offline) {
            _ = try await offline.signInOptions(issuer: issuer, clientID: "c1", codeChallenge: "ch1")
        }
        let garbled = NativePasskeyService(session: StubURLProtocol.session { _ in reply(200, #"{"publicKey":{}}"#) })
        await #expect(throws: PasskeyError.failed("decoding")) {
            _ = try await garbled.signInOptions(issuer: issuer, clientID: "c1", codeChallenge: "ch1")
        }
        let noCode = NativePasskeyService(session: StubURLProtocol.session { _ in reply(200, "{}") })
        let assertion = PasskeyAssertion(
            credentialID: Data([1]), clientDataJSON: Data(), authenticatorData: Data(), signature: Data())
        await #expect(throws: PasskeyError.failed("no_code")) {
            _ = try await noCode.verifySignIn(issuer: issuer, challengeID: "k", clientID: "c", assertion: assertion)
        }
    }
}
