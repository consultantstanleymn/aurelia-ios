#if canImport(Security)
import Foundation
import Security

/// The provider key, in the Keychain.
///
/// Not in the bundle and not in a file, deliberately. An API key compiled into an .ipa is one
/// `strings` away from being readable by anyone the .ipa is shared with, and the key in this app
/// can spend money. The Keychain is the only place iOS offers that is not also inside the app.
enum Keychain {
    /// Matches the access group in Support/Aurelia.entitlements.
    private static let service = "ch.stanley.aurelia"

    private enum Kind {
        static let account = "provider-api-key"
    }

    /// Writes the key, replacing any previous one.
    ///
    /// `AfterFirstUnlock` rather than `WhenUnlocked`: reminders are scheduled while the app is in
    /// the foreground and read back by `UNUserNotificationCenter` at fire time, which can happen
    /// with the screen locked but not before the first unlock after a reboot.
    static func save(_ key: String) throws {
        let data = Data(key.utf8)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Kind.account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            insert.merge(attributes) { _, new in new }
            let addStatus = SecItemAdd(insert as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError.status(addStatus) }
        } else if status != errSecSuccess {
            throw KeychainError.status(status)
        }
    }

    /// Reads the key back, or nil if none has been saved.
    static func read() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Kind.account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func clear() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Kind.account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    enum KeychainError: LocalizedError {
        case status(OSStatus)

        var errorDescription: String? {
            switch self {
            case let .status(code):
                // errSecMissingEntitlement is the one that actually happens in practice: the
                // access group in the entitlements has to match this service exactly, and xtool
                // applies the entitlements file after signing.
                if code == errSecMissingEntitlement {
                    return "The Keychain refused this app. Check the access group in the entitlements."
                }
                return "Keychain error \(code)."
            }
        }
    }
}
#endif
