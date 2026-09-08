import Foundation
import Security

/// Keychain-backed storage for the user's translation API key. The app's
/// own keychain needs no special entitlements; the value never reaches
/// UserDefaults, logs or diagnostics.
public enum APIKeychain {
    public static let service = "com.skillselector.translation"
    public static let account = "deepl-api-key"

    public enum KeychainError: Error, Equatable {
        case unhandled(OSStatus)
    }

    /// Inserts or updates the key. Idempotent.
    public static func save(_ key: String) throws {
        let data = Data(key.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [kSecValueData as String: data]
        switch SecItemCopyMatching(query as CFDictionary, nil) {
        case errSecSuccess:
            let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            guard status == errSecSuccess else { throw KeychainError.unhandled(status) }
        case errSecItemNotFound:
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let status = SecItemAdd(add as CFDictionary, nil)
            guard status == errSecSuccess else { throw KeychainError.unhandled(status) }
        case let status:
            throw KeychainError.unhandled(status)
        }
    }

    /// Returns the stored key, or nil when absent/unreadable.
    public static func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let key = String(data: data, encoding: .utf8),
              !key.isEmpty
        else { return nil }
        return key
    }

    /// Best-effort removal; a missing item counts as removed.
    public static func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
