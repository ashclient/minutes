import XCTest
import Security
@testable import Minutes

final class CredentialVaultTests: XCTestCase {
    func testConcurrentReadersShareOneCredentialRead() {
        var loads = 0
        let vault = CredentialVault(load: { _ in loads += 1; Thread.sleep(forTimeInterval: 0.02); return "token" }, store: { _, _ in }, exists: { _ in XCTFail("Cached value should supply presence"); return false })
        DispatchQueue.concurrentPerform(iterations: 12) { _ in
            do { XCTAssertEqual(try vault.read("google.tokens"), "token") }
            catch { XCTFail("Unexpected read failure: \(error)") }
        }
        XCTAssertEqual(loads, 1)
        XCTAssertTrue(try vault.contains("google.tokens"))
    }
    func testStatusCheckDoesNotReadSecretAndWritesReplaceCachedTokens() throws {
        var saved = "old", loads = 0
        let vault = CredentialVault(load: { _ in loads += 1; return saved }, store: { value, _ in saved = value }, exists: { _ in !saved.isEmpty })
        XCTAssertTrue(try vault.contains("google.tokens")); XCTAssertEqual(loads, 0)
        XCTAssertEqual(try vault.read("google.tokens"), "old")
        try vault.save("refreshed", service: "google.tokens")
        XCTAssertEqual(try vault.read("google.tokens"), "refreshed"); XCTAssertEqual(loads, 1)
        try vault.save("", service: "google.tokens")
        XCTAssertFalse(try vault.contains("google.tokens")); XCTAssertEqual(try vault.read("google.tokens"), "")
    }
    func testDenialDoesNotBecomeMissingTokenOrPromptRepeatedly() throws {
        var time = Date(timeIntervalSince1970: 100), loads = 0
        let vault = CredentialVault(load: { _ in loads += 1; if loads == 1 { throw AppFailure("Denied") }; return "approved" }, store: { _, _ in }, exists: { _ in true }, now: { time })
        XCTAssertThrowsError(try vault.read("google.tokens"))
        XCTAssertThrowsError(try vault.read("google.tokens")); XCTAssertEqual(loads, 1)
        XCTAssertTrue(try vault.contains("google.tokens"))
        time = time.addingTimeInterval(9)
        XCTAssertEqual(try vault.read("google.tokens"), "approved"); XCTAssertEqual(loads, 2)
    }
    func testFailedWritePreservesPreviouslyApprovedCredential() throws {
        let vault = CredentialVault(load: { _ in "old" }, store: { _, _ in throw AppFailure("Locked") }, exists: { _ in true })
        XCTAssertEqual(try vault.read("notion"), "old")
        XCTAssertThrowsError(try vault.save("new", service: "notion"))
        XCTAssertEqual(try vault.read("notion"), "old")
    }
    func testRealKeychainPresenceQueryUsesMetadataWithoutLoadingCredential() throws {
        let service = "tests." + UUID().uuidString
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.minutes.local." + service, kSecAttrAccount as String: "api-key"]
        var item = query; item[kSecValueData as String] = Data("synthetic-test-value".utf8)
        XCTAssertEqual(SecItemAdd(item as CFDictionary, nil), errSecSuccess)
        defer { SecItemDelete(query as CFDictionary) }
        XCTAssertTrue(try CloudKey.contains(service: service))
        XCTAssertEqual(SecItemDelete(query as CFDictionary), errSecSuccess)
        XCTAssertFalse(try CloudKey.contains(service: service))
    }

}
