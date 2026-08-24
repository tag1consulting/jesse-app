import Foundation

// Where and how to reach the SENTINEL — the second process that watches the bridge. It is a
// separate host, port and token from `JesseConfig` on purpose: the sentinel's whole job is
// to be reachable when the bridge is not, so sharing either the port or the bearer token
// with the thing it supervises would make it fail in the same breath.
//
// This file holds the config value, the Keychain slot it lives in beside `JesseConfig`, and
// the ONE pairing parser both configs come out of.

/// Where and how to reach the sentinel. A plain `Sendable` value, exactly like `JesseConfig`,
/// so the client can carry it across actor boundaries without a hop.
public struct SentinelConfig: Sendable, Equatable, Codable {
    /// The sentinel's default port (`JESSE_SENTINEL_PORT`), used when a pairing payload or a
    /// stored config omits/can't parse one. One above the bridge's, which is what the
    /// deployment uses and what the QR carries.
    public static let defaultPort = 8766

    public var host: String
    public var port: Int
    public var token: String

    public init(host: String, port: Int = SentinelConfig.defaultPort, token: String) {
        self.host = host
        self.port = port
        self.token = token
    }

    /// The sentinel reuses `JesseConfig`'s host sanitizer rather than growing a second one:
    /// people paste the same shapes into both fields (a full URL, `host:port`, a trailing
    /// dot), and two parsers would drift.
    private var asBridgeShape: JesseConfig { JesseConfig(host: host, port: port, token: token) }

    public var normalizedHost: String { asBridgeShape.normalizedHost }
    public var effectivePort: Int { asBridgeShape.effectivePort }

    /// Build a request URL. Nil for a malformed/blank host so the caller throws a clean
    /// `notConfigured` rather than sending to a silently-wrong place.
    public func endpoint(_ path: String) -> URL? {
        var c = URLComponents()
        let h = normalizedHost
        guard !h.isEmpty else { return nil }
        c.scheme = "http"
        c.host = h
        c.port = effectivePort
        c.path = path.hasPrefix("/") ? path : "/" + path
        return c.url
    }

    /// Whether the sentinel is paired: a host and a token are both set. Every Ops surface
    /// keys off this — an unpaired sentinel gets a "pair the sentinel" call to action rather
    /// than a screen full of failures.
    public var isConfigured: Bool { !normalizedHost.isEmpty && !token.isEmpty }
}

// MARK: - Pairing

/// What one `jesse://pair?…` payload carries: the bridge, always, and the sentinel when the
/// bridge was started with one.
///
/// ONE parser, not two, because the two answers have to be taken from the same scan. The
/// three sentinel keys are ADDITIVE (`shost`, `sport`, `stoken`) — the bridge emits them
/// only when a sentinel is configured, so a payload without them is not an error and must
/// not disturb a sentinel this device already has. See `bridge/src/startup.rs`.
public struct PairingPayload: Sendable, Equatable {
    public var bridge: JesseConfig
    /// Nil when the QR carried no sentinel keys — which is "this payload says nothing about
    /// the sentinel", NOT "there is no sentinel".
    public var sentinel: SentinelConfig?

    public init(bridge: JesseConfig, sentinel: SentinelConfig?) {
        self.bridge = bridge
        self.sentinel = sentinel
    }

    /// Parse a `jesse://pair?host=&port=&token=[&shost=&sport=&stoken=]` payload.
    ///
    /// Returns nil for anything that is not a well-formed pairing URL with a non-empty bridge
    /// host and token — the sentinel half is never load-bearing for whether the scan worked,
    /// because a bridge with no sentinel is an ordinary, supported deployment.
    public static func parse(_ raw: String) -> PairingPayload? {
        guard let bridge = JesseConfig.fromPairing(raw) else { return nil }
        return PairingPayload(bridge: bridge, sentinel: sentinelFromPairing(raw))
    }

    /// The sentinel half alone, or nil when the payload carries no (usable) sentinel keys.
    /// Both a host and a token are required: a half-filled sentinel would pair a screen that
    /// then 401s on every call, which is worse than no sentinel at all.
    static func sentinelFromPairing(_ raw: String) -> SentinelConfig? {
        guard let c = URLComponents(string: raw), c.scheme == "jesse", c.host == "pair" else {
            return nil
        }
        let items = c.queryItems ?? []
        func v(_ n: String) -> String? { items.first { $0.name == n }?.value }
        guard let host = v("shost"), let token = v("stoken"),
              !host.isEmpty, !token.isEmpty else { return nil }
        return SentinelConfig(host: host,
                              port: Int(v("sport") ?? "") ?? SentinelConfig.defaultPort,
                              token: token)
    }
}

// MARK: - Keychain storage

/// The sentinel's credentials live in the SAME Keychain service as the bridge's, under one
/// extra account (`sentinel`) holding a small JSON object.
///
/// One account rather than three (`sentinel_host`/`sentinel_port`/`sentinel_token`) because
/// the three fields are only ever meaningful together: a partial write would leave a config
/// that points somewhere real with the wrong token, and the Keychain gives no transaction to
/// prevent that across three items. One item is written or it is not.
public extension KeychainConfigStore {
    /// The Keychain account the sentinel config is stored under, beside `host`/`port`/`token`.
    static let sentinelAccount = "sentinel"

    /// The stored sentinel config, or an empty (unconfigured) one when nothing is paired or
    /// the stored blob no longer decodes. A blob that cannot be read is treated as absent
    /// rather than surfaced: the recovery is re-pairing either way.
    func loadSentinel() -> SentinelConfig {
        guard let raw = readAccount(Self.sentinelAccount),
              let data = raw.data(using: .utf8),
              let cfg = try? JSONDecoder().decode(SentinelConfig.self, from: data) else {
            return SentinelConfig(host: "", token: "")
        }
        return cfg
    }

    /// Persist the sentinel config. Returns `false` when the write failed (a locked Keychain),
    /// so a caller can say "the sentinel token didn't save" instead of losing it silently.
    @discardableResult
    func saveSentinel(_ c: SentinelConfig) -> Bool {
        guard let data = try? JSONEncoder().encode(c),
              let text = String(data: data, encoding: .utf8) else { return false }
        return writeAccount(Self.sentinelAccount, text)
    }
}
