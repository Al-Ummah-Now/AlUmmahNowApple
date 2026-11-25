import AUNCoreBridge
import AunCore
import Foundation

/// The trust anchors this build carries (wiki AUN-APP-UPDATES §3.5, §9): the Apple repo's offline root public key and the
/// key list it signed. Public; the private key never leaves its owner.
public enum AppUpdateKeys {
    public static let rootKeys = ["Mf2IQATA0Y1AF5eaeIr41q3bFuogvHqz2rktf8A4nag="]

    static func bundled(_ name: String) -> String? {
        Bundle.module.url(forResource: name, withExtension: nil).flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    }
}

/// Update checks for Studio for Mac, the only Apple app that isn't from a store: aun-core's `UpdateChecker` holds the key
/// list, the signature rules and what the app remembers. Nothing is installed here.
public actor CoreAppUpdateService: AppUpdateChecking {
    public static let repo = "AlUmmahNowApple"
    /// The one page Download opens: fixed here, never taken from an answer or the network (§4.1.1).
    public static let downloadPage = URL(string: "https://github.com/Al-Ummah-Now/AlUmmahNowApple/releases")!
    private static let stateKey = "AUNCoreAppUpdateState"

    private let checker: UpdateChecker
    private let hasRootKey: Bool
    private let identity: AppUpdateIdentity
    private let apiBaseURL: URL
    private let session: URLSession
    private let defaults: UserDefaults

    public init(
        identity: AppUpdateIdentity, apiBaseURL: URL, rootKeys: [String] = AppUpdateKeys.rootKeys,
        keyList: String? = AppUpdateKeys.bundled("update-keys.json"),
        keyListSignature: String? = AppUpdateKeys.bundled("update-keys.json.sig"),
        session: URLSession = .shared, defaults: sending UserDefaults = .standard
    ) throws {
        let state = defaults.string(forKey: Self.stateKey)
        do {
            checker = try UpdateChecker(
                repo: Self.repo, rootKeys: rootKeys, installedVersion: identity.version, betaChannel: identity.beta,
                stateJson: state, bundledKeyList: keyList, bundledKeyListSig: keyListSignature)
        } catch {
            // A bundled list that doesn't verify (a test refuses such a build) trusts nothing; it must not stop the app
            checker = try UpdateChecker(
                repo: Self.repo, rootKeys: rootKeys, installedVersion: identity.version, betaChannel: identity.beta,
                stateJson: state, bundledKeyList: nil, bundledKeyListSig: nil)
        }
        hasRootKey = !rootKeys.isEmpty
        self.identity = identity
        self.apiBaseURL = apiBaseURL
        self.session = session
        self.defaults = defaults
    }

    private struct Body: Decodable {
        struct Update: Decodable { let enabled: Bool }
        let update: Update
    }

    public func check() async throws -> AppUpdateCheck {
        let (data, response) = try await session.data(for: identity.request(apiBaseURL: apiBaseURL))
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw CoreError.http(status: (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        guard let body = try? JSONDecoder().decode(Body.self, from: data), let text = String(data: data, encoding: .utf8),
            let answer = try? checker.applyAnswer(updateJson: text, deviceHasUpdate: nil)
        else { throw CoreError.decoding }
        checker.markChecked(atMs: Int64(Date().timeIntervalSince1970 * 1000))
        save()
        return AppUpdateCheck(enabled: body.update.enabled, prompt: prompt(answer), checkHours: Int(answer.checkHours))
    }

    public func offlinePrompt() -> AppUpdatePrompt? {
        checker.offlinePromptKind() == .requiredBar ? AppUpdatePrompt(kind: .requiredSoon) : nil
    }

    public func dismiss(version: String) {
        checker.dismiss(version: version)
        save()
    }

    private func save() { defaults.set(checker.stateJson(), forKey: Self.stateKey) }

    private func prompt(_ answer: UpdatePrompt) -> AppUpdatePrompt? {
        let kind: AppUpdatePrompt.Kind
        switch answer.kind {
        case .none: return nil
        case .notice: kind = .notice
        case .requiredBar: kind = .requiredSoon
        case .forced: kind = .forced
        }
        let action = action(answer)
        // Nothing this build may do about it: no notice, and never the forced screen
        if action == nil, kind != .requiredSoon { return kind == .forced ? AppUpdatePrompt(kind: .requiredSoon) : nil }
        return AppUpdatePrompt(
            kind: kind, version: answer.version, notes: text(answer.notesEn, answer.notesAr),
            message: text(answer.messageEn, answer.messageAr), action: kind == .requiredSoon ? nil : action)
    }

    /// The root-key rules, kept here as well as in aun-core: no URL of an answer is ever opened.
    private func action(_ answer: UpdatePrompt) -> AppUpdateAction? {
        switch answer.action {
        case "notice": return hasRootKey ? nil : .download
        case "download": return .download
        case "install":
            guard identity.source == .direct, hasRootKey, let tag = answer.tag,
                let manifest = answer.manifestUrl, checker.allowedDownloadUrl(url: manifest), let url = URL(string: manifest)
            else { return .download }
            return .install(manifest: url, tag: tag)
        default: return nil
        }
    }

    private func text(_ en: String?, _ ar: String?) -> AppUpdateText? {
        guard let en, let ar, !en.isEmpty, !ar.isEmpty else { return nil }
        return AppUpdateText(en: en, ar: ar)
    }
}
