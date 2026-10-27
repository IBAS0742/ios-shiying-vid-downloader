import Foundation
import Security

/// Minimal keychain wrapper shared by the Telegram and SnapAny credentials.
enum KeychainStore {
    static let defaultService = "com.ibas.shiying.telegram"

    static func string(for account: String, service: String = defaultService) -> String? {
        var query = baseQuery(account: account, service: service)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ value: String, for account: String, service: String = defaultService) {
        guard let data = value.data(using: .utf8) else { return }
        let query = baseQuery(account: account, service: service)
        let attributes: [String: Any] = [kSecValueData as String: data]

        if SecItemUpdate(query as CFDictionary, attributes as CFDictionary) == errSecItemNotFound {
            var insert = query
            insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(insert as CFDictionary, nil)
        }
    }

    static func remove(_ account: String, service: String = defaultService) {
        SecItemDelete(baseQuery(account: account, service: service) as CFDictionary)
    }

    private static func baseQuery(account: String, service: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
