import Foundation
import Security

// Bridge connection config for the macOS client: host, port, bearer token, plus the
// URL builder every request uses. Modeled on the iOS `JesseConfig` but standalone —
// the iOS type is entangled with the health-context client and lives in an iOS-only
// file. The token is kept in the Keychain (survives reinstalls, not plaintext in
// UserDefaults); host/port live in UserDefaults.

/// Where and how to reach the bridge. `nonisolated`/`Sendable` so the networking
/// client can carry it across actor boundaries without a hop.
nonisolated struct MacBridgeConfig: Sendable, Equatable {
    /// The bridge's default port (`JESSE_PORT`), used when the host entry omits one.
    static let defaultPort = 8765

    var host: String   // hostname or 100.x tailnet IP — no scheme, port, or path
    var port: Int
    var token: String

    static let empty = MacBridgeConfig(host: "", port: defaultPort, token: "")

    var isConfigured: Bool { !host.isEmpty && !token.isEmpty }

    /// Build a request URL for `path` ("/jesse/sessions"). Uses `URLComponents` with
    /// host/port set explicitly so a host that looks scheme-like can't make
    /// `URL(string:)` misparse it. Returns nil for an empty/invalid host.
    func endpoint(_ path: String) -> URL? {
        guard !host.isEmpty else { return nil }
        var c = URLComponents()
        c.scheme = "http"
        c.host = host
        c.port = port
        c.path = path
        return c.url
    }

    /// Reduce whatever the user typed/pasted into a bare host + optional lifted port.
    /// People paste full URLs ("http://box.ts.net:8765/health"), "host:port", or a
    /// bare host; strip the scheme, any path/query, and lift an embedded port.
    static func sanitize(_ raw: String) -> (host: String, port: Int?) {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip a leading scheme or protocol-relative "//".
        if let range = s.range(of: "://") { s = String(s[range.upperBound...]) }
        else if s.hasPrefix("//") { s = String(s.dropFirst(2)) }
        // Drop any path/query/fragment.
        if let slash = s.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) {
            s = String(s[..<slash])
        }
        s = s.trimmingCharacters(in: .whitespaces)
        // Lift an embedded ":port" (but not part of an IPv6 literal, which we don't
        // support here — tailnet hosts are IPv4 or DNS names).
        var port: Int?
        if let colon = s.lastIndex(of: ":"), s.filter({ $0 == ":" }).count == 1 {
            let portStr = String(s[s.index(after: colon)...])
            if let p = Int(portStr), (1...65535).contains(p) {
                port = p
                s = String(s[..<colon])
            }
        }
        return (s.lowercased(), port)
    }
}

/// Minimal Keychain wrapper for the bearer token — one generic-password item keyed by
/// a fixed account. Non-sandboxed app, so the default (login) keychain is used with no
/// access group. All `nonisolated` static functions over value types, so callable from
/// any isolation domain.
enum MacKeychain {
    private static let service = "com.tag1.JesseMac.bridge"
    private static let account = "bridge-token"

    static func saveToken(_ token: String) {
        let data = Data(token.utf8)
        // Delete any existing item first so this is an upsert.
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        guard !token.isEmpty else { return }  // empty token == "no token stored"
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    static func loadToken() -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data, let token = String(data: data, encoding: .utf8)
        else { return "" }
        return token
    }
}

/// Observable config store the SwiftUI shell binds to. Host/port in UserDefaults, the
/// token in the Keychain. `@MainActor` because the UI reads and mutates it; it hands a
/// plain `Sendable` `MacBridgeConfig` to the networking client for off-main work.
@MainActor
@Observable
final class MacConfigStore {
    private enum Keys {
        static let host = "bridge.host"
        static let port = "bridge.port"
    }

    private(set) var config: MacBridgeConfig

    init(defaults: UserDefaults = .standard) {
        let host = defaults.string(forKey: Keys.host) ?? ""
        let port = defaults.object(forKey: Keys.port) as? Int ?? MacBridgeConfig.defaultPort
        self.config = MacBridgeConfig(host: host, port: port, token: MacKeychain.loadToken())
    }

    var isConfigured: Bool { config.isConfigured }

    /// Persist a new config: sanitize the host, lift an embedded port, store the token
    /// in the Keychain and host/port in UserDefaults.
    func save(host rawHost: String, port rawPort: Int?, token: String,
              defaults: UserDefaults = .standard) {
        let (host, liftedPort) = MacBridgeConfig.sanitize(rawHost)
        let port = liftedPort ?? rawPort ?? MacBridgeConfig.defaultPort
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        defaults.set(host, forKey: Keys.host)
        defaults.set(port, forKey: Keys.port)
        MacKeychain.saveToken(trimmedToken)
        config = MacBridgeConfig(host: host, port: port, token: trimmedToken)
    }
}
