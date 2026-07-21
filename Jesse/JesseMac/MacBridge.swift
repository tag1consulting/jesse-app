import Foundation
import Observation
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
    private static let keychainService = "com.tag1.JesseMac.bridge"
    private let store = KeychainConfigStore(service: keychainService)

    private(set) var config: JesseConfig

    init() {
        self.config = KeychainConfigStore(service: Self.keychainService).load()
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
}
