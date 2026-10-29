import Foundation
import Security
import LocalAuthentication

// Serialize access so concurrent calendar loads share one successful Keychain
// read. Secrets remain only in process memory; persistent storage stays Keychain.
final class CredentialVault: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    private var failures: [String: (Date, Error)] = [:]
    private let load: (String) throws -> String
    private let store: (String, String) throws -> Void
    private let exists: (String) throws -> Bool
    private let now: () -> Date
    init(load: @escaping (String) throws -> String, store: @escaping (String, String) throws -> Void, exists: @escaping (String) throws -> Bool, now: @escaping () -> Date = Date.init) {
        self.load = load; self.store = store; self.exists = exists; self.now = now
    }
    func read(_ service: String) throws -> String {
        lock.lock(); defer { lock.unlock() }
        if let value = values[service] { return value }
        if let (time, error) = failures[service], now().timeIntervalSince(time) < 8 { throw error }
        do {
            let value = try load(service)
            values[service] = value; failures[service] = nil
            return value
        } catch {
            // A denied prompt must not trigger several more prompts from queued
            // calendar requests. Do not mistake a denial for a missing token.
            failures[service] = (now(), error)
            throw error
        }
    }
    func save(_ value: String, service: String) throws {
        lock.lock(); defer { lock.unlock() }
        try store(value, service)
        values[service] = value; failures[service] = nil
    }
    func contains(_ service: String) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        if let value = values[service] { return !value.isEmpty }
        return try exists(service)
    }
}

enum CloudKey {
    private static let vault = CredentialVault(load: readStored, store: saveStored, exists: containsStored)
    private static func query(_ service: String) -> [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.minutes.local." + service, kSecAttrAccount as String: "api-key"] }
    static func read(service: String = "openrouter") throws -> String { try vault.read(service) }
    static func save(_ key: String, service: String = "openrouter") throws { try vault.save(key, service: service) }
    // Status labels need only unencrypted metadata, never credential bytes.
    static func contains(service: String) throws -> Bool { try vault.contains(service) }
    private static func containsStored(_ service: String) throws -> Bool {
        var q = query(service)
        q[kSecReturnAttributes as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        let context = LAContext(); context.interactionNotAllowed = true
        q[kSecUseAuthenticationContext as String] = context
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return false }
        guard status == errSecSuccess else { throw AppFailure("Could not check the saved Keychain item (\(status)).") }
        return true
    }
    private static func readStored(_ service: String) throws -> String {
        var q = query(service); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return "" }
        if status == errSecUserCanceled || status == errSecAuthFailed || status == errSecInteractionNotAllowed {
            throw AppFailure("Keychain access was not approved. Unlock your login keychain and allow Minutes, then retry in a few seconds.")
        }
        guard status == errSecSuccess, let data = result as? Data else { throw AppFailure("Could not read the API key from Keychain (\(status)).") }
        return String(decoding: data, as: UTF8.self)
    }
    private static func saveStored(_ key: String, _ service: String) throws {
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
