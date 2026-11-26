import AUNCoreBridge
import Foundation

/// `DeletionRecordStoring` on the Keychain, one item per account: a record holds the receipt that settles a lost answer, and
/// outlives a reinstall of the app, as the account's session does.
public final class KeychainDeletionRecords: DeletionRecordStoring, @unchecked Sendable {
    private static let prefix = "deletion."
    private let storage: KeychainStorage

    public init(service: String) { storage = KeychainStorage(service: service) }

    public func all() throws -> [DeletionRecord] {
        try storage.list(prefix: Self.prefix).compactMap { key in
            guard let data = try storage.get(key: key) else { return nil }
            if let record = try? JSONDecoder().decode(DeletionRecord.self, from: data) { return record }
            // Unreadable here (a newer version's): it still means that a deletion started.
            let id = String(key.dropFirst(Self.prefix.count))
            return DeletionRecord(accountID: id, label: id, stage: .erasing)
        }
    }

    public func save(_ record: DeletionRecord) throws {
        try storage.set(key: Self.prefix + record.accountID, value: JSONEncoder().encode(record))
    }

    public func remove(_ accountID: String) throws { try storage.delete(key: Self.prefix + accountID) }
}
