import Foundation

/// A channel the signed-in person can work in (`GET /api/channels/access`).
public struct StudioChannel: Identifiable, Hashable, Sendable, Decodable {
    public enum Role: String, Sendable, Decodable { case owner, admin, editor, moderator }

    public var id: String
    public var name: String
    public var nameLocalized: LocalizedText?
    public var avatarURL: URL?
    public var handle: String?
    public var isMain: Bool
    public var role: Role
    public var capabilities: [String]
    public var isSuspended: Bool

    enum CodingKeys: String, CodingKey {
        case id, name, nameLocalized, handle, isMain, role, capabilities, isSuspended
        case avatarURL = "avatarUrl"
    }

    public init(
        id: String, name: String, nameLocalized: LocalizedText? = nil, avatarURL: URL? = nil, handle: String? = nil,
        isMain: Bool = false, role: Role = .owner, capabilities: [String] = [], isSuspended: Bool = false
    ) {
        self.id = id
        self.name = name
        self.nameLocalized = nameLocalized
        self.avatarURL = avatarURL
        self.handle = handle
        self.isMain = isMain
        self.role = role
        self.capabilities = capabilities
        self.isSuspended = isSuspended
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        nameLocalized = try? c.decodeIfPresent(LocalizedText.self, forKey: .nameLocalized)
        avatarURL = try? c.decodeIfPresent(URL.self, forKey: .avatarURL)
        handle = try c.decodeIfPresent(String.self, forKey: .handle)
        isMain = try c.decodeIfPresent(Bool.self, forKey: .isMain) ?? false
        role = (try? c.decodeIfPresent(Role.self, forKey: .role)) ?? .moderator
        capabilities = try c.decodeIfPresent([String].self, forKey: .capabilities) ?? []
        isSuspended = try c.decodeIfPresent(Bool.self, forKey: .isSuspended) ?? false
    }

    public func can(_ capability: String) -> Bool { role == .owner || capabilities.contains(capability) }
    /// Uploads are open to owners, admins and editors of a channel that is not suspended (as on the web).
    public var canUpload: Bool { !isSuspended && can("video.upload") }

    public func displayName(_ language: AppLanguage) -> String {
        nameLocalized?.value(for: language, fallback: name) ?? name
    }
}
