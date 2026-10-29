import Foundation
import Security

/// The backup passphrase for automatic encrypted backups lives here, in this iPhone's Keychain: separate from every backup file,
/// never synced, and unavailable until the phone has been unlocked once after a restart.
enum Keychain {
    private static let service = "com.example.monoapp.backup"

    static func set(_ value: String, account: String) -> Bool {
        delete(account: account)
        let attrs: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account,
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        return SecItemAdd(attrs as CFDictionary, nil) == errSecSuccess
    }

    static func get(account: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account,
                                kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func delete(account: String) -> Bool {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        let s = SecItemDelete(q as CFDictionary)
        return s == errSecSuccess || s == errSecItemNotFound
    }
}
