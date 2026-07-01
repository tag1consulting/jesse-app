import XCTest
import Security
@testable import Jesse

/// `ConfigStore` (Keychain-backed host/port/token) had no round-trip coverage —
/// only the save-failure path was tested. These drive `save` → `load` through the
/// injected SecItem seams against an in-memory backend (the test bundle lacks
/// Keychain entitlements), proving what's written reads back, and that an empty
/// Keychain loads the defaults.
final class ConfigStoreRoundTripTests: XCTestCase {

    override func tearDown() {
        ConfigStore.addItem = SecItemAdd
        ConfigStore.copyItem = SecItemCopyMatching
        ConfigStore.deleteItem = SecItemDelete
        super.tearDown()
    }

    /// Install an in-memory Keychain keyed by the item's account attribute, so
    /// add/copy/delete behave like the real store for the round-trip.
    private func installInMemoryKeychain() -> () -> [String: Data] {
        final class Box { var store: [String: Data] = [:] }
        let box = Box()
        func account(_ d: CFDictionary) -> String? {
            (d as NSDictionary)[kSecAttrAccount as String] as? String
        }
        ConfigStore.addItem = { attrs, _ in
            guard let acct = account(attrs) else { return errSecParam }
            box.store[acct] = (attrs as NSDictionary)[kSecValueData as String] as? Data
            return errSecSuccess
        }
        ConfigStore.copyItem = { query, out in
            guard let acct = account(query), let data = box.store[acct] else { return errSecItemNotFound }
            out?.pointee = data as CFData
            return errSecSuccess
        }
        ConfigStore.deleteItem = { query in
            if let acct = account(query) { box.store[acct] = nil }
            return errSecSuccess
        }
        return { box.store }
    }

    func testSaveThenLoadRoundTrips() {
        _ = installInMemoryKeychain()
        let ok = ConfigStore.save(JesseConfig(host: "laptop.tailnet.ts.net", port: 9000, token: "secret-tok"))
        XCTAssertTrue(ok)

        let loaded = ConfigStore.load()
        XCTAssertEqual(loaded.host, "laptop.tailnet.ts.net")
        XCTAssertEqual(loaded.port, 9000)
        XCTAssertEqual(loaded.token, "secret-tok")
    }

    func testSaveOverwritesPreviousValue() {
        _ = installInMemoryKeychain()
        ConfigStore.save(JesseConfig(host: "old", port: 1, token: "old-tok"))
        ConfigStore.save(JesseConfig(host: "new", port: 2, token: "new-tok"))
        let loaded = ConfigStore.load()
        XCTAssertEqual(loaded.host, "new")
        XCTAssertEqual(loaded.port, 2)
        XCTAssertEqual(loaded.token, "new-tok")
    }

    func testLoadOnEmptyKeychainReturnsDefaults() {
        _ = installInMemoryKeychain()   // nothing saved
        let loaded = ConfigStore.load()
        XCTAssertEqual(loaded.host, "")
        XCTAssertEqual(loaded.token, "")
        XCTAssertEqual(loaded.port, JesseConfig.defaultPort, "an absent port falls back to the default")
    }
}
