import Foundation
import Security
import os

public protocol KeychainStoring: Sendable {
    func set(_ value: String, for key: String) throws
    func get(_ key: String) throws -> String?
    func delete(_ key: String) throws
}

public enum KeychainError: Error, LocalizedError {
    case unhandled(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .unhandled(let status):
            return "Keychain error: \(status)"
        }
    }
}

/// Thread-safe Keychain wrapper. The `os_unfair_lock` guards the
/// delete-then-add sequence in `set()` against races (B6 fix).
public final class KeychainStore: KeychainStoring, @unchecked Sendable {
    public let service: String
    private let lock = OSAllocatedUnfairLock()

    public init(service: String = "com.aispotlight.api") { self.service = service }

    public func set(_ value: String, for key: String) throws {
        let data = Data(value.utf8)
        try lock.withLock {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: key,
            ]
            // SecItemUpdate first; if the item doesn't exist yet, fall back to add.
            let updateAttrs: [String: Any] = [
                kSecValueData as String: data,
                // Bind accessibility so the key doesn't roam or be readable while locked.
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            ]
            var status = SecItemUpdate(query as CFDictionary, updateAttrs as CFDictionary)
            if status == errSecItemNotFound {
                var addQuery = query
                addQuery[kSecValueData as String] = data
                addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                status = SecItemAdd(addQuery as CFDictionary, nil)
            }
            guard status == errSecSuccess else { throw KeychainError.unhandled(status) }
        }
    }

    public func get(_ key: String) throws -> String? {
        try lock.withLock {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: key,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            var item: AnyObject?
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            if status == errSecItemNotFound { return nil }
            guard status == errSecSuccess, let data = item as? Data else {
                throw KeychainError.unhandled(status)
            }
            return String(data: data, encoding: .utf8)
        }
    }

    public func delete(_ key: String) throws {
        try lock.withLock {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: key,
            ]
            SecItemDelete(query as CFDictionary)
        }
    }
}

/// In-memory keychain for tests. Not thread-safe by design — tests serialize access.
public final class InMemoryKeychain: KeychainStoring, @unchecked Sendable {
    private var store: [String: String] = [:]
    private let lock = OSAllocatedUnfairLock()
    public init() {}
    public func set(_ v: String, for k: String) throws { lock.withLock { store[k] = v } }
    public func get(_ k: String) throws -> String? { lock.withLock { store[k] } }
    public func delete(_ k: String) throws { lock.withLock { store.removeValue(forKey: k) } }
}
