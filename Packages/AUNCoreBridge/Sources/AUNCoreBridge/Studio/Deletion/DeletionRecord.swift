import Foundation

/// What an erase reported it could not remove.
public enum DeletionLeftover: String, Codable, Hashable, Sendable {
    /// A channel the server could not read: it stays until an admin removes it, and the team is told.
    case channel
    /// Other records. Nobody is told about these.
    case other
}

/// How far a deletion got, saved before and after every step that matters (wiki guides/data-lifecycle.md).
public enum DeletionStage: String, Codable, Hashable, Sendable, CaseIterable, Comparable {
    /// The person confirmed and their sign-in is recent. Nothing was called.
    case confirmed
    /// Their uploads stand still. Nothing was called.
    case uploadsHeld
    /// Erase passes were sent: some content may be gone.
    case erasing
    /// An erase over everything finished; the sign-in account is left.
    case contentErased
    /// `DELETE /account` was sent and not answered yet: it may be finished.
    case deleteSent
    /// The account is gone; what is left is this device's own clean-up.
    case deleted

    public static func < (a: DeletionStage, b: DeletionStage) -> Bool {
        (allCases.firstIndex(of: a) ?? 0) < (allCases.firstIndex(of: b) ?? 0)
    }

    /// The server was asked to remove something.
    public var started: Bool { self >= .erasing }
}

/// A deletion that started on this device. It has no expiry: one from last week still means content may be gone.
public struct DeletionRecord: Codable, Hashable, Sendable {
    public let accountID: String
    /// What the person calls the account, to name it when it is signed out.
    public var label: String
    public var stage: DeletionStage
    /// Opaque, bound to the account by the server; handed back unread.
    public var resumeToken: String?
    public var leftover: Set<DeletionLeftover> = []
    /// The server asked to wait until then.
    public var notBefore: Date?
    /// Auth's receipt for this attempt (`POST /account/deletion-receipt`). Once the account is deleted no token can be had,
    /// so it settles a lost answer. It opens nothing: Auth only says whether the account is deleted.
    public var receipt: String?
    /// Auth takes the receipt until then.
    public var receiptExpires: Date?

    public init(
        accountID: String, label: String, stage: DeletionStage, resumeToken: String? = nil,
        leftover: Set<DeletionLeftover> = [], notBefore: Date? = nil, receipt: String? = nil, receiptExpires: Date? = nil
    ) {
        self.accountID = accountID
        self.label = label
        self.stage = stage
        self.resumeToken = resumeToken
        self.leftover = leftover
        self.notBefore = notBefore
        self.receipt = receipt
        self.receiptExpires = receiptExpires
    }

    /// `DELETE /account` was sent, its answer was lost, and no receipt is left to ask with: only the person can settle it.
    public var unsettled: Bool { stage == .deleteSent && receipt == nil }
}

/// The deletions that started on this device. "Unknown" must never look like "nothing started", so reading throws.
public protocol DeletionRecordStoring: Sendable {
    func all() throws -> [DeletionRecord]
    func save(_ record: DeletionRecord) throws
    func remove(_ accountID: String) throws
}

/// Records held in memory, for fixtures and tests.
public final class MemoryDeletionRecords: DeletionRecordStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String: DeletionRecord]
    private var failing = false

    public init(_ records: [DeletionRecord] = []) {
        stored = Dictionary(records.map { ($0.accountID, $0) }) { $1 }
    }

    /// From now on every read and write throws, as a locked Keychain does.
    public func fail(_ fails: Bool) { lock.withLock { failing = fails } }

    private func check() throws { if failing { throw CoreError.forbidden } }

    public func all() throws -> [DeletionRecord] {
        try lock.withLock {
            try check()
            return stored.values.sorted { $0.accountID < $1.accountID }
        }
    }

    public func save(_ record: DeletionRecord) throws {
        try lock.withLock {
            try check()
            stored[record.accountID] = record
        }
    }

    public func remove(_ accountID: String) throws {
        try lock.withLock {
            try check()
            stored[accountID] = nil
        }
    }
}
