import Foundation
import Security

/// Stores the Anthropic API key in the login keychain. Using Keychain instead
/// of UserDefaults keeps the key out of plist backups and application support
/// snapshots.
enum TranslationKeychain {
    private static let service = "com.captr.app.translation"
    private static let account = "anthropic-api-key"

    static func load() throws -> String? {
        var query: [String: Any] = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.status(status) }
        guard let data = item as? Data, let value = String(data: data, encoding: .utf8) else {
            throw KeychainError.invalidData
        }
        return value
    }

    static func save(_ value: String) throws {
        let data = Data(value.utf8)

        let query = baseQuery()
        let attributes: [String: Any] = [kSecValueData as String: data]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insert = baseQuery()
            insert[kSecValueData as String] = data
            let insertStatus = SecItemAdd(insert as CFDictionary, nil)
            guard insertStatus == errSecSuccess else { throw KeychainError.status(insertStatus) }
        } else if status != errSecSuccess {
            throw KeychainError.status(status)
        }
    }

    static func delete() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.status(status)
        }
    }

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

private enum KeychainError: LocalizedError {
    case status(OSStatus)
    case invalidData

    var errorDescription: String? {
        switch self {
        case .status(let status):
            let detail = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            return "Keychain error: \(detail)"
        case .invalidData:
            return "The saved API key could not be read."
        }
    }
}
