import Foundation

/// A comment in the channel's Held tab, waiting for the channel to review it (`GET /api/channels/:id/comments?tab=held`).
public struct HeldComment: Identifiable, Hashable, Sendable, Decodable {
    public var id: String
    public var text: String
    /// The video or post it was left on.
    public var targetTitle: String
    /// The author's name as the server resolves it (display name, else first + last); never a handle.
    public var authorName: String
    public var createdAt: Date?

    public init(id: String, text: String, targetTitle: String, authorName: String, createdAt: Date? = nil) {
        self.id = id
        self.text = text
        self.targetTitle = targetTitle
        self.authorName = authorName
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey { case id, text, targetTitle, author, createdAt }
    /// The author's profile: `resolvedDisplayName` when the server sends it, else display name, else first + last.
    /// The `username` handle is never a name.
    struct Author: Decodable {
        let resolvedDisplayName: String?
        let displayName: String?
        let firstName: String?
        let lastName: String?

        var name: String {
            let full = [firstName, lastName].compactMap(Self.clean).joined(separator: " ")
            return Self.clean(resolvedDisplayName) ?? Self.clean(displayName) ?? (full.isEmpty ? "" : full)
        }

        private static func clean(_ text: String?) -> String? {
            guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            return text
        }
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        targetTitle = try c.decodeIfPresent(String.self, forKey: .targetTitle) ?? ""
        authorName = (try? c.decodeIfPresent(Author.self, forKey: .author))?.name ?? ""
        createdAt = try? c.decodeIfPresent(Date.self, forKey: .createdAt)
    }
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
