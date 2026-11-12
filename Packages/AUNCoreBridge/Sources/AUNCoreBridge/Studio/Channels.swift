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

/// What the signed-in person may do as a creator (`GET /api/me/creator`). Plans are managed by admins; the app never
/// decides them, it only hides what the server says is not allowed.
public struct CreatorAccess: Hashable, Sendable, Decodable {
    public var canUpload: Bool
    public var canCreateChannel: Bool
    /// An admin ran "Delete videos data": writes are refused until it is restored.
    public var pendingDeletion: Bool
    public var tierName: String?

    public init(canUpload: Bool = true, canCreateChannel: Bool = true, pendingDeletion: Bool = false, tierName: String? = nil) {
        self.canUpload = canUpload
        self.canCreateChannel = canCreateChannel
        self.pendingDeletion = pendingDeletion
        self.tierName = tierName
    }

    enum CodingKeys: String, CodingKey { case canUpload, canCreateChannel, pendingDeletion, tier }
    private struct Tier: Decodable { let name: String? }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        canUpload = try c.decodeIfPresent(Bool.self, forKey: .canUpload) ?? false
        canCreateChannel = try c.decodeIfPresent(Bool.self, forKey: .canCreateChannel) ?? false
        pendingDeletion = try c.decodeIfPresent(Bool.self, forKey: .pendingDeletion) ?? false
        tierName = (try? c.decodeIfPresent(Tier.self, forKey: .tier))?.name
    }
}
