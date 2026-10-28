import Foundation
import Security

enum CloudKey {
    private static func query(_ service: String) -> [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.minutes.local." + service, kSecAttrAccount as String: "api-key"] }
    static func read(service: String = "openrouter") throws -> String {
        var q = query(service); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = result as? Data else { throw AppFailure("Could not read the API key from Keychain (\(status)).") }
        return String(decoding: data, as: UTF8.self)
    }
    static func save(_ key: String, service: String = "openrouter") throws {
        let query = query(service)
        if key.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw AppFailure("Could not remove the Keychain key (\(status)).") }; return
        }
        let values = [kSecValueData as String: Data(key.utf8)]
        var status = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            var item = query; item[kSecValueData as String] = Data(key.utf8)
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw AppFailure("Could not save the key in Keychain (\(status)).") }
    }
}
