import XCTest
import Security
@testable import Jesse_Mac
import JesseNetworking

/// The macOS bridge config store: the Keychain round trip that pairing depends on, the
/// exact service/account keys pinned so they can't silently change again, and the one-time
/// migration that recovers a pairing stored by a pre-1.0(61) build.
///
/// This is the root cause behind three of the reported symptoms (transcript won't load, the
/// Health tab dead-ends at "not paired", New Chat is disabled): when the shared
/// `KeychainConfigStore` replaced the old per-field storage, the Keychain account key for
/// the token changed (`bridge-token` -> `token`) and the host/port moved out of
/// UserDefaults, with no migration, so an already-paired user loaded an empty config and
/// the whole app read as unconfigured. The old suite covered only pure helpers, so it
/// missed this entirely.
@MainActor
final class MacConfigStoreTests: XCTestCase {

    private let service = MacConfigStore.keychainService

    private func defaults() -> UserDefaults { UserDefaults(suiteName: "cfg.\(UUID().uuidString)")! }

    // MARK: - Pinned keys

    func testKeychainServiceAndLegacyKeysArePinned() {
        // A pinned test so a future rename is caught HERE (as a red test) rather than in the
        // field (as a silently-orphaned pairing).
        XCTAssertEqual(MacConfigStore.keychainService, "com.tag1.JesseMac.bridge")
        XCTAssertEqual(MacConfigStore.legacyTokenAccount, "bridge-token")
        XCTAssertEqual(MacConfigStore.legacyHostDefaultsKey, "bridge.host")
        XCTAssertEqual(MacConfigStore.legacyPortDefaultsKey, "bridge.port")
    }

    func testSharedStoreWritesHostPortTokenAccounts() {
        let kc = FakeKeychain()
        kc.configStore(service: service).save(JesseConfig(host: "studio.ts.net", port: 9000, token: "tok"))
        // The exact accounts the shared store uses, pinned so a change is caught here.
        XCTAssertEqual(kc.string(account: "host"), "studio.ts.net")
        XCTAssertEqual(kc.string(account: "port"), "9000")
        XCTAssertEqual(kc.string(account: "token"), "tok")
    }

    // MARK: - Round trip and gating

    func testSaveThenReloadReportsConfiguredWithFieldsIntact() {
        let kc = FakeKeychain()
        let d = defaults()

        let first = MacConfigStore(store: kc.configStore(service: service), defaults: d,
                                   legacyCopy: kc.copy, legacyDelete: kc.delete)
        XCTAssertFalse(first.isConfigured, "a fresh empty store is unconfigured")
        first.save(host: "studio.ts.net", port: 9000, token: "secret-tok")
        XCTAssertTrue(first.isConfigured)

        // A NEW store on next launch, same Keychain: the pairing must survive.
        let next = MacConfigStore(store: kc.configStore(service: service), defaults: d,
                                  legacyCopy: kc.copy, legacyDelete: kc.delete)
        XCTAssertTrue(next.isConfigured, "New Chat, send, hydrate, and the Health tab all gate on this")
        XCTAssertEqual(next.config.host, "studio.ts.net")
        XCTAssertEqual(next.config.port, 9000)
        XCTAssertEqual(next.config.token, "secret-tok")
    }

    func testEmptyStoreIsUnconfiguredAndDoesNotMigrateSpuriously() {
        let kc = FakeKeychain()
        let store = MacConfigStore(store: kc.configStore(service: service), defaults: defaults(),
                                   legacyCopy: kc.copy, legacyDelete: kc.delete)
        XCTAssertFalse(store.isConfigured)
        XCTAssertEqual(store.config.host, "")
        XCTAssertEqual(store.config.token, "")
    }

    // MARK: - Legacy migration (the lockout fix)

    func testLegacyPairingIsMigratedToConfigured() {
        let kc = FakeKeychain()
        let d = defaults()
        // Pre-1.0(61) layout: token in the Keychain under `bridge-token`, host/port in
        // UserDefaults. Nothing under the new accounts.
        kc.seed(account: MacConfigStore.legacyTokenAccount, "legacy-secret")
        d.set("old-studio.ts.net", forKey: MacConfigStore.legacyHostDefaultsKey)
        d.set(9100, forKey: MacConfigStore.legacyPortDefaultsKey)

        let store = MacConfigStore(store: kc.configStore(service: service), defaults: d,
                                   legacyCopy: kc.copy, legacyDelete: kc.delete)

        XCTAssertTrue(store.isConfigured, "a previously-paired user must not be locked out after upgrading")
        XCTAssertEqual(store.config.host, "old-studio.ts.net")
        XCTAssertEqual(store.config.port, 9100)
        XCTAssertEqual(store.config.token, "legacy-secret")
    }

    func testLegacyMigrationRewritesNewAccountsAndClearsLegacy() {
        let kc = FakeKeychain()
        let d = defaults()
        kc.seed(account: MacConfigStore.legacyTokenAccount, "legacy-secret")
        d.set("old-studio.ts.net", forKey: MacConfigStore.legacyHostDefaultsKey)
        d.set(9100, forKey: MacConfigStore.legacyPortDefaultsKey)

        _ = MacConfigStore(store: kc.configStore(service: service), defaults: d,
                           legacyCopy: kc.copy, legacyDelete: kc.delete)

        // Rewritten under the shared accounts...
        XCTAssertEqual(kc.string(account: "token"), "legacy-secret")
        XCTAssertEqual(kc.string(account: "host"), "old-studio.ts.net")
        // ...and the legacy items are cleared so the migration runs at most once.
        XCTAssertFalse(kc.has(account: MacConfigStore.legacyTokenAccount))
        XCTAssertNil(d.string(forKey: MacConfigStore.legacyHostDefaultsKey))
        XCTAssertNil(d.object(forKey: MacConfigStore.legacyPortDefaultsKey))
    }

    func testLegacyMigrationNeedsBothTokenAndHost() {
        // Token but no host: nothing to target, stay unconfigured.
        let kc1 = FakeKeychain(); kc1.seed(account: MacConfigStore.legacyTokenAccount, "t")
        let s1 = MacConfigStore(store: kc1.configStore(service: service), defaults: defaults(),
                                legacyCopy: kc1.copy, legacyDelete: kc1.delete)
        XCTAssertFalse(s1.isConfigured)

        // Host but no token: a token is required to talk to the bridge, stay unconfigured.
        let kc2 = FakeKeychain(); let d2 = defaults()
        d2.set("host.ts.net", forKey: MacConfigStore.legacyHostDefaultsKey)
        let s2 = MacConfigStore(store: kc2.configStore(service: service), defaults: d2,
                                legacyCopy: kc2.copy, legacyDelete: kc2.delete)
        XCTAssertFalse(s2.isConfigured)
    }

    func testAlreadyConfiguredStoreIgnoresLegacy() {
        let kc = FakeKeychain()
        let d = defaults()
        // A current pairing under the new accounts...
        kc.configStore(service: service).save(JesseConfig(host: "current.ts.net", port: 8765, token: "current"))
        // ...plus a stale legacy token that must NOT clobber it.
        kc.seed(account: MacConfigStore.legacyTokenAccount, "stale")
        d.set("stale-host.ts.net", forKey: MacConfigStore.legacyHostDefaultsKey)

        let store = MacConfigStore(store: kc.configStore(service: service), defaults: d,
                                   legacyCopy: kc.copy, legacyDelete: kc.delete)
        XCTAssertEqual(store.config.host, "current.ts.net")
        XCTAssertEqual(store.config.token, "current")
        // The legacy token is left untouched (migration only runs when the new store is empty).
        XCTAssertTrue(kc.has(account: MacConfigStore.legacyTokenAccount))
    }
}
