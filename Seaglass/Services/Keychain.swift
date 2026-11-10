import Foundation
import Security

/// Small wrapper around the keychain for the account's session and Last.fm's secrets.
/// On iPhone and iPad it falls back to UserDefaults if the keychain is unavailable for the signing
/// setup in use. On a Mac the app is self-signed, without the entitlements the iPhone's keychain
/// needs there, so it uses the Mac's own (login) keychain instead, and never UserDefaults. When the
/// app's own keychain calls can't reach it (they couldn't on CI's Macs, see Tools/MacAccountCheck),
/// the AppKit plug-in writes it with macOS's file-based keychain API.
@MainActor
enum Keychain {
    private static let service = "onda"
    private static let isMac = ProcessInfo.processInfo.isMacCatalystApp

    /// On a Mac, how the last write went (OSStatus codes), for CI's account check.
    private(set) static var macStatus = ""

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
        guard let value else {
            if isMac { _ = MacBridge.shared.keychainSet(nil, service: service, account: key) }
            return
        }

        var item = query
        item[kSecValueData as String] = Data(value.utf8)
        if !isMac { item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock }
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status != errSecSuccess else {
            if isMac {
                macStatus = "app 0"
                // An older copy kept by the plug-in would otherwise come back if this one goes.
                _ = MacBridge.shared.keychainSet(nil, service: service, account: key)
            }
            return
        }
        if isMac {
            let legacy = MacBridge.shared.keychainSet(value, service: service, account: key)
            macStatus = "app \(status), plug-in \(legacy.map(String.init) ?? "none")"
        } else {
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
        if isMac { return MacBridge.shared.keychainGet(service: service, account: key) }
        return UserDefaults.standard.string(forKey: fallbackKey(key))
    }

    private static func fallbackKey(_ key: String) -> String { "keychain-fallback.\(key)" }
}
