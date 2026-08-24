import Foundation
import JesseNetworking

// Which process a control verb is sent to, and how both platforms hand the Ops screens their
// two configs.
//
// The routing rule is one line and it is worth stating out loud: WHEN A SENTINEL IS PAIRED,
// fire and enable go through it. Not because the sentinel does anything different — it
// proxies straight to the bridge — but because it is the path that still works when the
// bridge's HTTP surface is wedged and its process is alive, which is the only moment anyone
// reaches for these buttons. With no sentinel paired the app talks to the bridge directly,
// which is exactly what it did before this screen existed.

/// The pair of configs every Ops surface is built from. A value, not a store: each platform
/// loads its own Keychain and hands this down, so nothing in `JesseOps` knows what a Keychain
/// is or which service the app namespaces it under.
public struct OpsConfiguration: Sendable, Equatable {
    public var bridge: JesseConfig
    public var sentinel: SentinelConfig

    /// The `URLSession` both clients are built on. Nil — the default — means each client uses
    /// its own bounded production session, which have deliberately different ceilings (the
    /// sentinel's calls run eight probes or wait out a health poll). Injectable ONLY so a test
    /// can supply a `URLProtocol`-backed stub; nothing in either app passes it.
    public var session: URLSession?

    public init(bridge: JesseConfig, sentinel: SentinelConfig, session: URLSession? = nil) {
        self.bridge = bridge
        self.sentinel = sentinel
        self.session = session
    }

    /// Equality is about WHICH MACHINES this points at, so the injected session is not part of
    /// it: two configurations naming the same bridge and sentinel are the same configuration,
    /// and `URLSession` has no meaningful equality anyway.
    public static func == (a: OpsConfiguration, b: OpsConfiguration) -> Bool {
        a.bridge == b.bridge && a.sentinel == b.sentinel
    }

    public var bridgeClient: JesseBridgeClient {
        JesseBridgeClient(config: bridge, session: session ?? JesseBridgeClient.boundedSession)
    }

    /// Nil when no sentinel is paired — which is what every "pair the sentinel" call to
    /// action keys off, rather than each screen re-deriving it.
    public var sentinelClient: SentinelClient? {
        guard sentinel.isConfigured else { return nil }
        return SentinelClient(config: sentinel, session: session ?? SentinelClient.boundedSession)
    }

    /// THE ROUTING DECISION, in one expression: the sentinel when there is one, the bridge
    /// otherwise. Returned as the shared protocol so the caller cannot accidentally depend on
    /// which it got.
    public var scheduleControl: any ScheduleControlling {
        sentinelClient ?? bridgeClient
    }

    /// Which process `scheduleControl` picked, for the one-line note the Schedule screen
    /// prints under its list. A user who cannot see which door a button goes through cannot
    /// tell a sentinel outage from a bridge one.
    public var scheduleControlRoute: Route { sentinel.isConfigured ? .sentinel : .bridge }

    public enum Route: String, Sendable, Equatable {
        case bridge, sentinel

        public var label: String {
            switch self {
            case .bridge: return "sent straight to the bridge"
            case .sentinel: return "sent through the sentinel"
            }
        }
    }
}
