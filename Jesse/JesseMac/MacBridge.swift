import Foundation
import Observation
import Security
// Re-export the shared networking layer so the rest of the macOS target sees JesseConfig,
// the wire types, and JesseBridgeClient by their bare names.
@_exported import JesseNetworking

// Bridge connection config for the macOS client. The value type (`JesseConfig`) and the
// Keychain persistence (`KeychainConfigStore`) now live once in JesseNetworking, shared
// with the iOS app — this file keeps only the SwiftUI-facing observable store the shell
// binds to. Before this, `MacBridgeConfig` + `MacKeychain` were a parallel
// re-implementation of the iOS config type and its Keychain writer.

/// Observable config store the SwiftUI shell binds to. Host, port, and token all persist
/// through the shared Keychain store (service `com.tag1.JesseMac.bridge`), so the macOS
/// client stores its bridge credentials exactly as the iOS app does — token in the
/// Keychain, not plaintext UserDefaults. `@MainActor` because the UI reads and mutates it;
/// it hands a plain `Sendable` `JesseConfig` to the networking client for off-main work.
@MainActor
@Observable
final class MacConfigStore {
    /// The Keychain namespace for the macOS client's bridge credentials — distinct from
    /// the iOS app's `com.tag1.jesse` so the two never collide on a shared login keychain.
    /// A pinned test guards this exact string so a future refactor can't silently orphan a
    /// paired user's stored credentials again (which is exactly what happened when the
    /// shared `KeychainConfigStore` replaced the old per-field storage; see the migration
    /// below).
    static let keychainService = "com.tag1.JesseMac.bridge"

    // Legacy storage keys used by builds before App 1.0 (61), when the Mac stored the
    // token in the Keychain under a fixed account and the host/port in UserDefaults (the
    // `MacKeychain` + `MacBridgeConfig` era). The shared `KeychainConfigStore` reads a
    // different set of Keychain accounts (`host`/`port`/`token`), so without a migration a
    // previously-paired user loads an EMPTY config after upgrading and the whole app reads
    // as unconfigured (no transcript loads, New Chat is disabled, the Health tab dead-ends
    // at "not paired"). These constants let the store recover that pairing once.
    static let legacyTokenAccount = "bridge-token"
    static let legacyHostDefaultsKey = "bridge.host"
    static let legacyPortDefaultsKey = "bridge.port"

    // A @MainActor class's synthesized deinit is MainActor-isolated; when the last release
    // happens off the main actor (e.g. a temporary released inside an XCTest autoclosure)
    // the isolated-deinit executor hop aborts. There is nothing to tear down here (both
    // stored values are value types), so an explicit nonisolated deinit keeps teardown
    // off-actor safe. Same pattern as `HealthDashboardModel` and the JesseSearch models.
    nonisolated deinit {}

    private let store: KeychainConfigStore

    private(set) var config: JesseConfig

    /// Production: the real shared Keychain store plus standard UserDefaults, with a
    /// one-time migration from the pre-1.0(61) layout when the new store is empty.
    convenience init() {
        self.init(store: KeychainConfigStore(service: Self.keychainService), defaults: .standard)
    }

    /// Injectable initializer (production convenience above; tests supply an in-memory
    /// Keychain store and a scratch defaults suite). On load, if the shared store holds no
    /// usable config, attempt the one-time legacy migration so an already-paired user keeps
    /// working across the storage-format change. The legacy Keychain primitives are used
    /// only here at init (not stored), so a test can drive migration against an in-memory
    /// backend without real Keychain entitlements.
    init(store: KeychainConfigStore,
         defaults: UserDefaults,
         legacyCopy: (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus = SecItemCopyMatching,
         legacyDelete: (CFDictionary) -> OSStatus = SecItemDelete) {
        self.store = store

        var loaded = store.load()
        if !loaded.isConfigured,
           let migrated = Self.migrateLegacyConfig(service: store.service, defaults: defaults, copy: legacyCopy) {
            // Rewrite under the shared store's accounts, then clear the legacy items so the
            // migration runs at most once.
            store.save(migrated)
            Self.clearLegacy(service: store.service, defaults: defaults, delete: legacyDelete)
            loaded = migrated
        }
        self.config = loaded
    }

    /// Test seam: build a store with a fixed config, bypassing the Keychain load and the
    /// legacy migration so a unit test can drive a configured coordinator without touching
    /// the login keychain.
    init(config: JesseConfig) {
        self.store = KeychainConfigStore(service: Self.keychainService)
        self.config = config
    }

    var isConfigured: Bool { config.isConfigured }

    /// Persist a new config: sanitize the host, lift an embedded port, and store all three
    /// fields through the shared Keychain seam.
    func save(host rawHost: String, port rawPort: Int?, token: String) {
        let (host, liftedPort) = JesseConfig.sanitize(rawHost)
        let port = liftedPort ?? rawPort ?? JesseConfig.defaultPort
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let cfg = JesseConfig(host: host, port: port, token: trimmedToken)
        store.save(cfg)
        config = cfg
    }

    // MARK: - Legacy migration (pre App 1.0 (61))

    /// Recover a pre-1.0(61) pairing: the token from the Keychain (account `bridge-token`
    /// in the same service) plus the host/port from UserDefaults. Returns nil unless BOTH a
    /// non-empty legacy token and a non-empty legacy host are present, so a genuinely
    /// never-paired install is left untouched (and reads as unconfigured, as it should).
    static func migrateLegacyConfig(service: String, defaults: UserDefaults,
                                    copy: (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus) -> JesseConfig? {
        guard let token = readLegacyToken(service: service, copy: copy), !token.isEmpty else { return nil }
        let rawHost = defaults.string(forKey: legacyHostDefaultsKey) ?? ""
        let (host, liftedPort) = JesseConfig.sanitize(rawHost)
        guard !host.isEmpty else { return nil }
        let storedPort = defaults.object(forKey: legacyPortDefaultsKey) as? Int
        let port = liftedPort ?? storedPort ?? JesseConfig.defaultPort
        return JesseConfig(host: host, port: port, token: token)
    }

    /// Read the legacy Keychain token item (generic password, account `bridge-token`).
    private static func readLegacyToken(service: String,
                                        copy: (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: legacyTokenAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard copy(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Remove the legacy Keychain token item and the legacy host/port defaults after a
    /// successful migration, so the recovery runs at most once.
    private static func clearLegacy(service: String, defaults: UserDefaults,
                                    delete: (CFDictionary) -> OSStatus) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: legacyTokenAccount,
        ]
        _ = delete(query as CFDictionary)
        defaults.removeObject(forKey: legacyHostDefaultsKey)
        defaults.removeObject(forKey: legacyPortDefaultsKey)
    }
}
