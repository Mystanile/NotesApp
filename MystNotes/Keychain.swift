import Foundation
import Security

/// Minimal generic-password Keychain wrapper for the AI helper's API keys.
/// Items are device-local (`AfterFirstUnlock`, not synchronizable): keys are
/// never synced, backed up into exports, or logged.
nonisolated enum Keychain {
    static let service = "com.mozynas.Mystnotes.ai"

    enum Account {
        static let featherless = "featherless"
        static let elevenlabs = "elevenlabs"
    }

    struct KeychainError: Error, LocalizedError {
        let status: OSStatus
        var errorDescription: String? { "Couldn't save the key to the Keychain (code \(status))." }
    }

    private static func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    /// Stores `value`, replacing any existing one. `nil` or empty removes it.
    static func set(_ value: String?, for account: String) throws {
        let query = baseQuery(account)
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let deleteStatus = SecItemDelete(query as CFDictionary)
        guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else {
            throw KeychainError(status: deleteStatus)
        }
        guard !trimmed.isEmpty else { return }
        var attributes = query
        attributes[kSecValueData as String] = Data(trimmed.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    static func get(_ account: String) -> String? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let string = String(data: data, encoding: .utf8),
              !string.isEmpty else { return nil }
        return string
    }
}
