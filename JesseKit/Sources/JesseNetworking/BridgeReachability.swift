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

    /// The app-wide model. Three tabs used to own one each, so three probes fired on
    /// every activation and a screen could show "offline" while the one next to it showed
    /// the day it had just fetched. One instance, one answer.
    ///
    /// It has to be a singleton rather than an `@Environment` value because the two
    /// non-view callers — the client's own request outcomes, and the connectivity
    /// monitor — have no view hierarchy to read from, and those are the callers that make
    /// it correct rather than merely shared.
    public static let shared = BridgeReachabilityModel()

    public private(set) var state: BridgeReachability = .unknown

    @ObservationIgnored private var task: Task<Void, Never>?
    /// When the last probe was STARTED. A probe is skipped if one ran inside
    /// `probeInterval`, which is what stops three tabs' activations (and a scene phase
    /// change, and a settings dismissal) from each costing a `GET /health`.
    @ObservationIgnored private var lastProbeAt: Date?
    /// Watches the path for a recovery, so coming back onto a network re-probes without
    /// anything on screen having to notice. `nil` until `follow` is called.
    @ObservationIgnored private var pathTask: Task<Void, Never>?

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

    /// The shortest gap between two probes. Every tab activation, every scene phase
    /// change and every settings dismissal asks for a refresh; without this that is four
    /// `GET /health` calls for one return to the app, all of which answer the same thing.
    public static let probeInterval: TimeInterval = 30

    /// Re-probe reachability for the current config. Unconfigured → `.unknown`
    /// (no banner). Success → `.reachable`; any transport/HTTP failure →
    /// `.unreachable`. Supersedes any in-flight probe so the latest config wins.
    ///
    /// THROTTLED to one probe per `probeInterval`, unless `force` is set. `force` is for
    /// the two events that are real news rather than a repeated question — a re-pairing
    /// (a different bridge entirely) and the network coming back — where the last answer
    /// is known to be about something else.
    public func refresh(config: JesseConfig, force: Bool = false, now: Date = Date()) {
        guard config.isConfigured else {
            task?.cancel()
            lastProbeAt = nil
            state = .unknown
            return
        }
        if !force, let last = lastProbeAt, now.timeIntervalSince(last) < Self.probeInterval {
            return
        }
        task?.cancel()
        lastProbeAt = now
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

    /// Set the state directly. Callers are the ones that have just completed a real round
    /// trip and therefore know the answer better than a `GET /health` from thirty seconds
    /// ago — the same precedence rule the dashboard models apply when they clear their own
    /// offline flag on a success. That is now every bridge call, not only a screen's: see
    /// `noteRequestOutcome`.
    public func adopt(_ state: BridgeReachability) {
        task?.cancel()
        self.state = state
    }

    /// Fold the outcome of ANY real bridge call into the state, and count it as a probe.
    ///
    /// This is the cheap half of the whole feature. A `POST /jesse` that answered is
    /// better evidence than a `GET /health` will ever be, and one that threw a transport
    /// error is better evidence of the opposite — so the app largely stops needing to
    /// probe at all, and the probe becomes what it should have been: the thing that runs
    /// when nothing else has happened lately.
    ///
    /// `succeeded` must mean "the bridge answered", not "the answer was a 200": a `404`
    /// for an unknown job id proves reachability just as well as a reply does. Callers
    /// pass `false` only for a transport-level failure.
    public func noteRequestOutcome(succeeded: Bool, now: Date = Date()) {
        lastProbeAt = now
        let resolved: BridgeReachability = succeeded ? .reachable : .unreachable
        guard resolved != state else { return }
        task?.cancel()
        state = resolved
    }

    /// Re-probe whenever the network comes back, so the banner clears itself instead of
    /// waiting for someone to switch tabs. Idempotent — a second call is a no-op.
    ///
    /// A recovery FORCES the probe past the throttle: the last answer was about a network
    /// this device no longer has, which is the definition of an answer worth replacing.
    /// An interface swap (Wi-Fi → cellular, both satisfied) is deliberately not a
    /// recovery; see `pathDidRecover`.
    public func follow(_ monitor: ConnectivityMonitor,
                       config: @escaping @MainActor () -> JesseConfig) {
        guard pathTask == nil else { return }
        let stream = monitor.paths()
        pathTask = Task { [weak self] in
            var previous: NetworkPathSnapshot?
            for await snapshot in stream {
                guard let self else { return }
                defer { previous = snapshot }
                guard let previous, pathDidRecover(from: previous, to: snapshot) else { continue }
                self.refresh(config: config(), force: true)
            }
        }
    }

    /// Stop following the path. The app never calls this; a test tearing down a model must.
    public func unfollow() {
        pathTask?.cancel()
        pathTask = nil
    }
}
