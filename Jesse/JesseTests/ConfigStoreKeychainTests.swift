import XCTest
import Security
@testable import Jesse

/// (Low) `ConfigStore.write` ignored `SecItemAdd`'s `OSStatus`, so a locked
/// Keychain (or a missing entitlement) silently lost the token. `save` now reports
/// whether every field persisted. Driven through the injectable `addItem` seam so
/// no real Keychain is touched.
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
}
