import Foundation

/// A comment in the channel's Held tab, waiting for the channel to review it (`GET /api/channels/:id/comments?tab=held`).
public struct HeldComment: Identifiable, Hashable, Sendable, Decodable {
    public var id: String
    public var text: String
    /// The video or post it was left on.
    public var targetTitle: String
    /// The target's title per language (`targetTitleLocalized`), when the server has one.
    public var targetTitleLocalized: LocalizedText?
    /// The author's name as the server resolves it (display name, else first + last); never a handle.
    public var authorName: String
    public var createdAt: Date?
    public var kind: HeldCommentKind?
    public var targetID: String?
    /// The person's ID, even when they commented as a channel.
    public var authorUserID: String?
    public var isHeldByModeration: Bool

    public var canModerate: Bool { kind != nil && targetID != nil && !isHeldByModeration }

    public init(
        id: String, text: String, targetTitle: String, targetTitleLocalized: LocalizedText? = nil, authorName: String,
        createdAt: Date? = nil, kind: HeldCommentKind? = nil, targetID: String? = nil, authorUserID: String? = nil,
        isHeldByModeration: Bool = false
    ) {
        self.id = id
        self.text = text
        self.targetTitle = targetTitle
        self.targetTitleLocalized = targetTitleLocalized
        self.authorName = authorName
        self.createdAt = createdAt
        self.kind = kind
        self.targetID = Author.clean(targetID)
        self.authorUserID = Author.clean(authorUserID)
        self.isHeldByModeration = isHeldByModeration
    }

    enum CodingKeys: String, CodingKey {
        case id, text, targetTitle, targetTitleLocalized, author, createdAt, kind, targetId, heldBy
    }
    /// The author's profile: `resolvedDisplayName` when the server sends it, else display name, else first + last.
    /// The `username` handle is never a name.
    struct Author: Decodable {
        let userId: String?
        let resolvedDisplayName: String?
        let displayName: String?
        let firstName: String?
        let lastName: String?

        var name: String {
            let full = [firstName, lastName].compactMap(Self.clean).joined(separator: " ")
            return Self.clean(resolvedDisplayName) ?? Self.clean(displayName) ?? (full.isEmpty ? "" : full)
        }

        static func clean(_ text: String?) -> String? {
            guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            return text
        }
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        targetTitle = try c.decodeIfPresent(String.self, forKey: .targetTitle) ?? ""
        targetTitleLocalized = try? c.decodeIfPresent(LocalizedText.self, forKey: .targetTitleLocalized)
        let author = try? c.decodeIfPresent(Author.self, forKey: .author)
        authorName = author?.name ?? ""
        authorUserID = Author.clean(author?.userId)
        kind = try? c.decodeIfPresent(HeldCommentKind.self, forKey: .kind)
        targetID = Author.clean(try? c.decodeIfPresent(String.self, forKey: .targetId))
        isHeldByModeration = (try? c.decodeIfPresent(String.self, forKey: .heldBy)) == "moderation"
        createdAt = try? c.decodeIfPresent(Date.self, forKey: .createdAt)
    }
}

extension HeldComment {
    /// The target's title in the page language, else its plain title (the comment text itself stays as written).
    public func displayTargetTitle(_ language: AppLanguage) -> String {
        targetTitleLocalized?.value(for: language, fallback: targetTitle) ?? targetTitle
    }
}

public enum HeldCommentKind: String, Sendable, Codable { case video, post }

public enum HeldCommentModeration: String, Sendable, Encodable { case approve, remove }

public enum CommentReportReason: String, Sendable, Encodable, CaseIterable {
    case childSafety = "child_safety"
    case inappropriate, spam, harassment, copyright, misinformation, other
}

/// The first comments of the Held tab and how many are waiting in all.
public struct HeldComments: Hashable, Sendable {
    public var items: [HeldComment]
    public var total: Int

    public init(items: [HeldComment], total: Int) {
        self.items = items
        self.total = total
    }
}
