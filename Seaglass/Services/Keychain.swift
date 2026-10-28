import Foundation
import Security

/// Small wrapper around the keychain for Last.fm secrets.
/// Falls back to UserDefaults if the keychain is unavailable for the signing setup in use.
enum Keychain {
    private static let service = "onda"

    static func set(_ value: String?, for key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
        UserDefaults.standard.removeObject(forKey: fallbackKey(key))
        guard let value else { return }

        var item = query
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        if SecItemAdd(item as CFDictionary, nil) != errSecSuccess {
            UserDefaults.standard.set(value, forKey: fallbackKey(key))
        }
    }

    static func get(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
           let data = result as? Data {
            return String(data: data, encoding: .utf8)
        }
        return UserDefaults.standard.string(forKey: fallbackKey(key))
    }

    private static func fallbackKey(_ key: String) -> String { "keychain-fallback.\(key)" }
}
