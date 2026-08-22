import Foundation
import Observation

/// Whether this device can currently reach the Jesse bridge. `unknown` is the
/// pre-probe state (cold launch, or unconfigured) — deliberately distinct from
/// `unreachable` so the offline banner never flashes before the first probe.
public enum BridgeReachability: Equatable, Sendable {
    case unknown
    case reachable
    case unreachable
}

/// The pure gate for the list-level offline banner: show it only when the app is
/// paired AND a probe has actually come back unreachable. Kept pure so the
/// decision is unit-tested without standing up the view or the network.
public func shouldShowOfflineBanner(isConfigured: Bool, reachability: BridgeReachability) -> Bool {
    isConfigured && reachability == .unreachable
}

/// Probes the bridge's `GET /health` to drive the offline banner, mirroring the
/// watch's `.queued` signal — so the device tells you the bridge is unreachable
/// *before* you compose and send, instead of only erroring after. The probe uses
/// a short-timeout session (not the 30s send session) so the banner appears
/// promptly; an unconfigured app stays `.unknown` (the pairing CTA covers that).
///
/// SHARED, and it did not start that way. This was an iOS-target file, which meant the
/// Mac had no reachability at all: no probe, no banner, no read-only day, and no way to
/// notice it had come back. It probes through `JesseBridgeClient` — the one client both
/// apps already use — so the answer cannot differ by platform.
@MainActor
@Observable
public final class BridgeReachabilityModel {
    // A @MainActor class's synthesized deinit is MainActor-isolated; a unit-test host
    // releases the model off the main actor, which would route through the
    // isolated-deinit executor hop and abort. Same pattern as the dashboard models.
    nonisolated deinit {}

    public private(set) var state: BridgeReachability = .unknown

    @ObservationIgnored private var task: Task<Void, Never>?

    /// The session every probe runs on. Injectable purely so a test can drive a real
    /// unreachable → reachable transition through a `URLProtocol` stub instead of
    /// asserting on a hand-set flag — which is the difference between testing this
    /// class and testing an assignment.
    @ObservationIgnored private let session: URLSession

    public init(session: URLSession = BridgeReachabilityModel.probeSession) {
        self.session = session
    }

    /// A dedicated short-timeout session so an unreachable host fails fast (≈5s)
    /// rather than after the send path's 30s ceiling.
    public static let probeSession: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 5
        c.timeoutIntervalForResource = 5
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    /// Re-probe reachability for the current config. Unconfigured → `.unknown`
    /// (no banner). Success → `.reachable`; any transport/HTTP failure →
    /// `.unreachable`. Supersedes any in-flight probe so the latest config wins.
    public func refresh(config: JesseConfig) {
        task?.cancel()
        guard config.isConfigured else {
            state = .unknown
            return
        }
        let probe = session
        task = Task { [weak self] in
            do {
                _ = try await JesseBridgeClient(config: config, session: probe).health()
                guard !Task.isCancelled else { return }
                self?.state = .reachable
            } catch {
                guard !Task.isCancelled else { return }
                self?.state = .unreachable
            }
        }
    }

    /// Await the probe currently in flight, if any. A test needs this because `refresh`
    /// deliberately does NOT block the caller — the banner must not make a screen wait —
    /// and polling for a state change is how a flaky test is written.
    public func settled() async {
        await task?.value
    }

    /// Set the state directly. The ONE caller is a screen that has just completed a real
    /// round trip to a data endpoint and therefore knows the answer better than a `GET
    /// /health` from thirty seconds ago — the same precedence rule the dashboard models
    /// apply when they clear their own offline flag on a success.
    public func adopt(_ state: BridgeReachability) {
        task?.cancel()
        self.state = state
    }
}
