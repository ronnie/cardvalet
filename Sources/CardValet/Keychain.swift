import Foundation
import Security

enum Keychain {
    private static let base: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "cardvalet",
        kSecAttrAccount as String: "pin",
    ]

    static func save(_ pin: String) {
        let data = Data(pin.utf8)
        let upd = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if upd == errSecItemNotFound {
            var add = base
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    /// True if a PIN item exists. Attribute-only query, so it never triggers the Keychain access prompt.
    static func has() -> Bool {
        var q = base; q[kSecReturnAttributes as String] = true
        return SecItemCopyMatching(q as CFDictionary, nil) == errSecSuccess
    }

    /// Removes the saved PIN. Not finding one counts as success.
    @discardableResult static func delete() -> Bool {
        let st = SecItemDelete(base as CFDictionary)
        return st == errSecSuccess || st == errSecItemNotFound
    }

    static func read() -> String? {
        var q = base
        q[kSecReturnData as String] = true
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
}
