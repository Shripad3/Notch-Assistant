import Foundation
import Security

/// Generic-password items for this app. Used for credentials that must not
/// sit in UserDefaults (Spotify tokens).
enum Keychain {
    private static let service = "dev.shripad.NotchAssistant"

    static func data(for account: String) -> Data? {
        var result: CFTypeRef?
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    static func set(_ data: Data, for account: String) {
        let match: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
        if SecItemUpdate(match as CFDictionary, [kSecValueData: data] as CFDictionary) == errSecItemNotFound {
            var item = match
            item[kSecValueData] = data
            item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(item as CFDictionary, nil)
        }
    }

    static func delete(_ account: String) {
        let match: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
        SecItemDelete(match as CFDictionary)
    }
}
