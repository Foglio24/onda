import Foundation
import Security

/// Small wrapper around the keychain for Last.fm secrets.
/// On iPhone and iPad it falls back to UserDefaults if the keychain is unavailable for the signing
/// setup in use. On a Mac the app is signed ad hoc, without the entitlements the iPhone's keychain
/// needs there, so it uses the Mac's own (login) keychain instead, and never UserDefaults: macOS may
/// ask, after an update, to let the new version read it.
enum Keychain {
    private static let service = "onda"
    private static let isMac = ProcessInfo.processInfo.isMacCatalystApp

    private static func query(_ key: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        if isMac { query[kSecUseDataProtectionKeychain as String] = false }
        return query
    }

    static func set(_ value: String?, for key: String) {
        let query = query(key)
        SecItemDelete(query as CFDictionary)
        UserDefaults.standard.removeObject(forKey: fallbackKey(key))
        guard let value else { return }

        var item = query
        item[kSecValueData as String] = Data(value.utf8)
        if !isMac { item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock }
        if SecItemAdd(item as CFDictionary, nil) != errSecSuccess, !isMac {
            UserDefaults.standard.set(value, forKey: fallbackKey(key))
        }
    }

    static func get(_ key: String) -> String? {
        var query = query(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
           let data = result as? Data {
            return String(data: data, encoding: .utf8)
        }
        return isMac ? nil : UserDefaults.standard.string(forKey: fallbackKey(key))
    }

    private static func fallbackKey(_ key: String) -> String { "keychain-fallback.\(key)" }
}
