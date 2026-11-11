import AunCore
import Foundation
import Security

/// aun-core's secure storage on the Keychain: one generic password item per key, readable after first unlock so
/// background uploads can refresh tokens, and never synced to iCloud.
public final class KeychainStorage: SecureStorage, @unchecked Sendable {
    private let service: String
    private let lock = NSLock()

    public init(service: String) { self.service = service }

    private func query(_ key: String? = nil) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: false,
        ]
        if let key { query[kSecAttrAccount as String] = key }
        return query
    }

    private func failure(_ status: OSStatus, _ action: String) -> AunError {
        .Storage(detail: "Keychain \(action) failed (\(status))")
    }

    public func get(key: String) throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        var request = query(key)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw failure(status, "read") }
        return result as? Data
    }

    public func set(key: String, value: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        let attributes: [String: Any] = [
            kSecValueData as String: value,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        var status = SecItemUpdate(query(key) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query(key).merging(attributes) { $1 } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw failure(status, "write") }
    }

    public func delete(key: String) throws {
        lock.lock()
        defer { lock.unlock() }
        let status = SecItemDelete(query(key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw failure(status, "delete") }
    }

    public func list(prefix: String) throws -> [String] {
        lock.lock()
        defer { lock.unlock() }
        var request = query()
        request[kSecReturnAttributes as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw failure(status, "list") }
        let items = result as? [[String: Any]] ?? []
        return items.compactMap { $0[kSecAttrAccount as String] as? String }.filter { $0.hasPrefix(prefix) }.sorted()
    }
}
