import Foundation
import Security
import os

// The bridge connection config (host, port, bearer token) plus the URL builder every
// request uses, and a Keychain-backed store seam both apps persist it through. This is
// the single cross-platform config surface: before this, the iOS `JesseConfig` and the
// Mac `MacBridgeConfig` were parallel re-implementations of the same value type, and each
// app had its own Keychain writer. One type, one store, both apps.

/// Where and how to reach the bridge. A plain `Sendable` value so the networking client
/// can carry it across actor boundaries without a hop.
public struct JesseConfig: Sendable, Equatable {
    /// The bridge's default port (`JESSE_PORT`), used when a pairing payload or a
    /// stored config omits/can't parse one.
    public static let defaultPort = 8765

    public var host: String   // e.g. "my-laptop.tailnet-1234.ts.net" or a 100.x IP
    public var port: Int
    public var token: String

    public init(host: String, port: Int, token: String) {
        self.host = host
        self.port = port
        self.token = token
    }

    /// A user-entered host, reduced to its bare components.
    public struct SanitizedHost: Sendable, Equatable {
        public var host: String   // hostname only — no scheme, port, path, or stray case
        public var port: Int?     // a port lifted out of the entry ("host:1234"), if any
    }

    /// Defensively parse whatever the user typed or pasted into the host field.
    /// People paste all sorts of things — a full URL copied from Safari
    /// ("http://host:8765/health"), an embedded ":port", a trailing path, a
    /// trailing FQDN dot, mixed case, stray whitespace. Left as-is, these make
    /// `URL(string:)` parse a *wrong* host (e.g. "http://host" → host == "http"),
    /// which then fails DNS as "hostname could not be found". Reduce any of those
    /// to a bare hostname (plus an optional port) so URL construction either
    /// yields the right host or cleanly fails to nil.
    public var sanitizedHost: SanitizedHost {
        var s = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // Strip a leading scheme ("http://", "https://") or protocol-relative "//".
        if let r = s.range(of: "://") {
            s = String(s[r.upperBound...])
        } else if s.hasPrefix("//") {
            s = String(s.dropFirst(2))
        }
        // Drop any pasted credentials ("user@host").
        if let at = s.lastIndex(of: "@") {
            s = String(s[s.index(after: at)...])
        }
        // Strip a path / query / fragment — everything from the first /, ?, or #.
        if let cut = s.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) {
            s = String(s[..<cut])
        }
        // Split off an embedded ":port". (The tailnet host is always a name or a
        // 100.x IPv4, so a single colon is unambiguously the port — we don't
        // handle bracketed IPv6 literals here.)
        var embeddedPort: Int?
        if let colon = s.firstIndex(of: ":") {
            embeddedPort = Int(s[s.index(after: colon)...])
            s = String(s[..<colon])
        }
        // Strip leading/trailing dots (FQDN trailing dot, stray leading dot).
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return SanitizedHost(host: s, port: embeddedPort)
    }

    /// Reduce whatever the user typed/pasted into a bare host plus an optional lifted
    /// port, without needing a full `JesseConfig` value. The macOS settings/pairing flow
    /// calls this on raw field/link text; it is exactly `sanitizedHost` over `raw`.
    public static func sanitize(_ raw: String) -> (host: String, port: Int?) {
        let s = JesseConfig(host: raw, port: defaultPort, token: "").sanitizedHost
        return (s.host, s.port)
    }

    /// The bare hostname the request will actually target.
    public var normalizedHost: String { sanitizedHost.host }

    /// Effective port: a port embedded in the host entry ("host:1234") wins over
    /// the separately-stored port, since pasting "host:1234" clearly means 1234.
    public var effectivePort: Int { sanitizedHost.port ?? port }

    /// Build a request URL with URLComponents (host/port/path set explicitly) so
    /// a malformed host yields nil — a clean `notConfigured` — rather than a
    /// silently-wrong host. `path` should be a leading-slash absolute path.
    public func endpoint(_ path: String) -> URL? {
        let h = normalizedHost
        guard !h.isEmpty else { return nil }
        var c = URLComponents()
        c.scheme = "http"
        c.host = h
        c.port = effectivePort
        c.path = path.hasPrefix("/") ? path : "/" + path
        return c.url
    }

    public var baseURL: URL? { endpoint("") }

    /// Whether the bridge is paired: a host and token are both set. Gates push
    /// authorization (don't ask before Jesse is even configured) and registration.
    public var isConfigured: Bool { !normalizedHost.isEmpty && !token.isEmpty }

    /// Parse a `jesse://pair?host=…&port=…&token=…` pairing payload (printed as a
    /// QR by the bridge on startup). Returns nil for anything that isn't a
    /// well-formed pairing URL with a non-empty host and token. Port defaults to
    /// 8765 when absent or unparseable.
    public static func fromPairing(_ raw: String) -> JesseConfig? {
        guard let c = URLComponents(string: raw),
              c.scheme == "jesse", c.host == "pair" else { return nil }
        let items = c.queryItems ?? []
        func v(_ n: String) -> String? { items.first { $0.name == n }?.value }
        guard let host = v("host"), let token = v("token"),
              !host.isEmpty, !token.isEmpty else { return nil }
        return JesseConfig(host: host, port: Int(v("port") ?? "") ?? JesseConfig.defaultPort, token: token)
    }
}

// MARK: - Keychain-backed config store

/// The persistence seam both apps store host/port/token through. Abstracted so a test
/// can supply an in-memory backend and so each app can namespace its own Keychain
/// service while sharing one implementation. Not `Sendable`: the store is used within a
/// single isolation domain (the iOS `ConfigStore` static facade, the Mac `MacConfigStore`
/// on the main actor), and the injectable Keychain seams are ordinary closures that a
/// test can build over a captured local backend.
public protocol BridgeConfigStoring {
    func load() -> JesseConfig
    @discardableResult func save(_ config: JesseConfig) -> Bool
}

/// The default `BridgeConfigStoring`: host, port, and token all live in the Keychain
/// (bound to this device, only while unlocked) so none is backup-eligible or
/// device-migratable and the token is never in plaintext UserDefaults. The three
/// `SecItem*` primitives are injectable seams so a test can force an `OSStatus` or an
/// in-memory backend without a real Keychain (a test bundle often lacks Keychain
/// entitlements). Parameterized by `service` so the iOS and Mac apps keep separate
/// namespaces while sharing this one implementation.
public struct KeychainConfigStore: BridgeConfigStoring {
    public let service: String
    let add: (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus
    let copy: (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus
    let delete: (CFDictionary) -> OSStatus

    private static let log = Logger(subsystem: "com.tag1.jesse", category: "keychain")

    public init(service: String,
                add: @escaping (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus = SecItemAdd,
                copy: @escaping (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus = SecItemCopyMatching,
                delete: @escaping (CFDictionary) -> OSStatus = SecItemDelete) {
        self.service = service
        self.add = add
        self.copy = copy
        self.delete = delete
    }

    public func load() -> JesseConfig {
        JesseConfig(
            host: read("host") ?? "",
            port: Int(read("port") ?? "") ?? JesseConfig.defaultPort,
            token: read("token") ?? ""
        )
    }

    /// Persist the config. Returns `false` if any field's write failed (e.g. the
    /// Keychain was locked), so a caller can surface "couldn't save the token"
    /// rather than silently losing it.
    @discardableResult
    public func save(_ c: JesseConfig) -> Bool {
        let okHost = write("host", c.host)
        let okPort = write("port", String(c.port))
        let okToken = write("token", c.token)
        return okHost && okPort && okToken
    }

    private func read(_ key: String) -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard copy(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    private func write(_ key: String, _ value: String) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        _ = delete(base as CFDictionary)
        var addAttrs = base
        addAttrs[kSecValueData as String] = value.data(using: .utf8)
        // Bind the item to THIS device, and only while unlocked: it's then neither
        // backup-eligible (an iCloud/iTunes backup can't carry the bearer token off
        // the device) nor migratable to another device on transfer. Without an
        // explicit accessibility, the Keychain default is backup-eligible.
        addAttrs[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = add(addAttrs as CFDictionary, nil)
        if status != errSecSuccess {
            // Surface, don't swallow: a locked Keychain (or missing entitlement)
            // would otherwise lose the token with no trace. The status code is not
            // a secret (the value itself is never logged).
            Self.log.error("SecItemAdd failed for key \(key, privacy: .public): OSStatus \(status)")
            return false
        }
        return true
    }
}
