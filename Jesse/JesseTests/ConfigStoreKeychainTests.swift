import XCTest
import Security
@testable import Jesse

/// (Low) `ConfigStore.write` ignored `SecItemAdd`'s `OSStatus`, so a locked
/// Keychain (or a missing entitlement) silently lost the token. `save` now reports
/// whether every field persisted. Driven through the injectable `addItem` seam so
/// no real Keychain is touched.
@MainActor
final class ConfigStoreKeychainTests: XCTestCase {

    override func tearDown() {
        ConfigStore.addItem = SecItemAdd   // restore the real Keychain add
        super.tearDown()
    }

    func testSaveReportsFailureWhenKeychainAddFails() {
        ConfigStore.addItem = { _, _ in errSecMissingEntitlement }  // a locked/denied write
        let ok = ConfigStore.save(JesseConfig(host: "laptop", port: 8765, token: "tok"))
        XCTAssertFalse(ok, "a Keychain add failure must be surfaced, not silently ignored")
    }

    func testSaveReportsSuccessWhenKeychainAddSucceeds() {
        ConfigStore.addItem = { _, _ in errSecSuccess }
        let ok = ConfigStore.save(JesseConfig(host: "laptop", port: 8765, token: "tok"))
        XCTAssertTrue(ok, "all writes succeeded → save reports success")
    }

    /// Every Keychain add must pin accessibility to
    /// `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, so the bearer token is neither
    /// backup-eligible nor device-migratable. Asserted against the exact add dict the
    /// store passes to `SecItemAdd`, via the injectable seam.
    func testEveryAddPinsThisDeviceOnlyAccessibility() {
        var addedAttributes: [[String: Any]] = []
        ConfigStore.addItem = { query, _ in
            addedAttributes.append(query as! [String: Any])
            return errSecSuccess
        }
        _ = ConfigStore.save(JesseConfig(host: "laptop", port: 8765, token: "tok"))

        XCTAssertFalse(addedAttributes.isEmpty, "the save must perform at least one add")
        for attrs in addedAttributes {
            let accessible = attrs[kSecAttrAccessible as String]
            XCTAssertNotNil(accessible, "every add must set kSecAttrAccessible")
            XCTAssertEqual(accessible as! CFString,
                           kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                           "the token must be unlocked-this-device-only: not backup-eligible, not migratable")
        }
    }
}
