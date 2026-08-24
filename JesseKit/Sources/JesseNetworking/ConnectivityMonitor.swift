import Foundation
import Network
import Observation

/// What this device's network looks like right now, as one value.
///
/// A struct rather than four loose properties because every consumer wants a
/// consistent set: "satisfied but expensive" and "expensive but no longer satisfied" are
/// different situations, and reading two `@Observable` properties in two re-evaluations
/// is how a screen ends up acting on half of a transition.
public struct NetworkPathSnapshot: Equatable, Sendable {
    /// The path can carry traffic. `false` is airplane mode, no Wi-Fi and no cell, or a
    /// captive network that has not let us out yet.
    public let isSatisfied: Bool
    /// The interface is metered — cellular, or a personal hotspot.
    public let isExpensive: Bool
    /// The USER has asked for less: iOS Low Data Mode on this interface.
    public let isConstrained: Bool
    /// Which interface is carrying it, reduced to the four cases anything here acts on.
    public let interfaceKind: NetworkInterfaceKind

    public init(isSatisfied: Bool, isExpensive: Bool, isConstrained: Bool,
                interfaceKind: NetworkInterfaceKind) {
        self.isSatisfied = isSatisfied
        self.isExpensive = isExpensive
        self.isConstrained = isConstrained
        self.interfaceKind = interfaceKind
    }

    /// The pre-first-path value. Deliberately `isSatisfied: true`: before the monitor has
    /// said anything, the app must behave exactly as it did before this type existed —
    /// try the request, and let the request's own failure be the evidence. Starting at
    /// `false` would gate the first send of every cold launch on a callback that has not
    /// fired yet.
    public static let unknown = NetworkPathSnapshot(isSatisfied: true, isExpensive: false,
                                                    isConstrained: false, interfaceKind: .unknown)
}

/// The interface carrying the path, reduced to what anything in this app acts on.
public enum NetworkInterfaceKind: String, Equatable, Sendable {
    case wifi
    case cellular
    case wired
    case other
    /// No interface at all (an unsatisfied path), or nothing has been reported yet.
    case unknown
}

/// Where `ConnectivityMonitor` gets its paths. The one seam: production reads
/// `NWPathMonitor`, a test hands over a stream it drives by hand, so every consumer of a
/// path change is exercised without a real radio.
public protocol NetworkPathSource: Sendable {
    /// The path stream. The first element is the current path, so a consumer that starts
    /// late is not left blind until the network next changes.
    func paths() -> AsyncStream<NetworkPathSnapshot>
}

/// The production source: one `NWPathMonitor` on its own background queue.
public struct SystemNetworkPathSource: NetworkPathSource {
    public init() {}

    public func paths() -> AsyncStream<NetworkPathSnapshot> {
        AsyncStream { continuation in
            let monitor = NWPathMonitor()
            // A dedicated serial queue, NOT the main one: `NWPathMonitor` calls its handler
            // for every interface change, and routing that through the main actor would put
            // radio churn on the same queue as the UI.
            let queue = DispatchQueue(label: "com.tag1.Jesse.connectivity", qos: .utility)
            monitor.pathUpdateHandler = { path in
                continuation.yield(NetworkPathSnapshot(path))
            }
            continuation.onTermination = { _ in monitor.cancel() }
            monitor.start(queue: queue)
        }
    }
}

public extension NetworkPathSnapshot {
    /// Reduce an `NWPath` to the four facts anything here acts on.
    init(_ path: NWPath) {
        let satisfied = path.status == .satisfied
        self.init(isSatisfied: satisfied,
                  isExpensive: path.isExpensive,
                  isConstrained: path.isConstrained,
                  interfaceKind: NetworkInterfaceKind(path))
    }
}

public extension NetworkInterfaceKind {
    /// The interface a path is using. Wi-Fi is checked before cellular because a phone
    /// with both up reports both, and the one actually carrying a satisfied path is the
    /// cheaper one.
    init(_ path: NWPath) {
        guard path.status == .satisfied else {
            self = .unknown
            return
        }
        if path.usesInterfaceType(.wifi) {
            self = .wifi
        } else if path.usesInterfaceType(.cellular) {
            self = .cellular
        } else if path.usesInterfaceType(.wiredEthernet) {
            self = .wired
        } else {
            self = .other
        }
    }
}

/// THE ONE place this app asks whether it has a network, and the one place anything
/// learns that the answer changed.
///
/// # Why it exists
///
/// Before this there was no `NWPathMonitor` anywhere in the app. Every recovery path was
/// therefore a human one: a failed poll ended in a manual "Re-check" button, the send
/// outbox never retried itself, and three tabs each stood up their own
/// `BridgeReachabilityModel` and fired a `GET /health` on every activation. The phone
/// knew it had come back onto a network the whole time and nothing asked it.
///
/// # What it is not
///
/// It is not reachability. `isSatisfied` says this device has a usable interface; it says
/// nothing about whether the laptop is awake, on the tailnet, or running the bridge.
/// That question is `BridgeReachabilityModel`'s, and the two are deliberately separate:
/// a satisfied path is the CUE to go and find out, never the answer.
@MainActor
@Observable
public final class ConnectivityMonitor {
    // A @MainActor class's synthesized deinit is MainActor-isolated; a unit-test host
    // releases the monitor off the main actor, which would route through the
    // isolated-deinit executor hop and abort. Same pattern as the reachability model.
    nonisolated deinit {}

    /// The app-wide monitor. One `NWPathMonitor` for the process — the system reports the
    /// same path to every instance, so N of them is N callbacks per interface change and
    /// N chances for two screens to hold different answers.
    public static let shared = ConnectivityMonitor()

    /// The current path. `.unknown` until the first callback lands (see its doc comment
    /// for why that reads as satisfied).
    public private(set) var path: NetworkPathSnapshot = .unknown

    /// Whether `start()` has run. Idempotent, so every plausible caller (the app's launch,
    /// a scene activation, a test) can simply call it.
    public private(set) var isRunning = false

    @ObservationIgnored private let source: NetworkPathSource
    @ObservationIgnored private var task: Task<Void, Never>?
    // The fan-out. Each consumer gets its own continuation; a finished one is dropped on
    // the next yield, so a screen that goes away does not leak a subscription.
    @ObservationIgnored private var subscribers: [UUID: AsyncStream<NetworkPathSnapshot>.Continuation] = [:]

    public init(source: NetworkPathSource = SystemNetworkPathSource()) {
        self.source = source
    }

    /// Begin monitoring. Idempotent — a second call is a no-op rather than a second
    /// `NWPathMonitor`.
    public func start() {
        guard !isRunning else { return }
        isRunning = true
        let stream = source.paths()
        task = Task { [weak self] in
            for await snapshot in stream {
                guard let self else { return }
                self.apply(snapshot)
            }
        }
    }

    /// Stop monitoring and finish every subscriber's stream. The app never calls this —
    /// connectivity is an app-lifetime concern — but a test must be able to tear one down.
    public func stop() {
        task?.cancel()
        task = nil
        isRunning = false
        for (_, continuation) in subscribers { continuation.finish() }
        subscribers.removeAll()
    }

    /// A stream of path changes for one consumer, starting with the CURRENT path so a
    /// late subscriber is not blind until the network next moves.
    ///
    /// Only genuine CHANGES are yielded after that first element: `NWPathMonitor` reports
    /// every interface event, and a consumer that re-attaches in-flight jobs on each one
    /// would do so several times for a single walk out of the front door.
    public func paths() -> AsyncStream<NetworkPathSnapshot> {
        let (stream, continuation) = AsyncStream<NetworkPathSnapshot>.makeStream()
        let id = UUID()
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor [weak self] in self?.subscribers[id] = nil }
        }
        continuation.yield(path)
        return stream
    }

    /// Wait until the path is satisfied, giving up after `timeout`. Returns whether it IS
    /// satisfied on return.
    ///
    /// The bound is what makes this safe to put in a poll loop. An unbounded wait would
    /// turn "the network is gone" into a turn that never resolves and a spinner that never
    /// stops — the exact shape the streaming path was rewritten to remove. On timeout the
    /// caller carries on and lets its own request produce the evidence.
    public func awaitSatisfied(timeout: TimeInterval) async -> Bool {
        if path.isSatisfied { return true }
        let stream = paths()
        return await withTaskGroup(of: Bool.self) { group in
            // Nonisolated on purpose: `AsyncStream` is `Sendable` and the element is a
            // value, so this child needs no hop back to the main actor per path change.
            group.addTask {
                for await snapshot in stream where snapshot.isSatisfied { return true }
                return false
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(timeout))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }

    /// Adopt one reported path. Internal rather than private so a test can drive a
    /// transition directly, without standing up a source, when the source is not what is
    /// under test.
    func apply(_ snapshot: NetworkPathSnapshot) {
        guard snapshot != path else { return }
        path = snapshot
        // Mirror it for the off-main readers before anyone is told, so a consumer woken by
        // the yield below cannot read a mirror that is one path behind.
        CurrentNetworkPath.set(snapshot)
        for (_, continuation) in subscribers { continuation.yield(snapshot) }
    }
}

/// The last reported path, readable from ANY isolation.
///
/// `ConnectivityMonitor` is `@MainActor` because it is `@Observable` and drives views. But
/// several of the decisions that depend on it are made OFF the main actor — the send path
/// composes its request body on a detached task, and the attachment downscaler is
/// `nonisolated` CPU work — and hopping to the main actor to ask "is this cellular?" in
/// the middle of either is a hop per turn for a value that changes a handful of times a
/// day.
///
/// So the monitor mirrors each path here as it adopts it. One writer (the monitor, on the
/// main actor), many readers, a lock between them, and a value type crossing — which is
/// why this is a mirror rather than a second source of truth.
public enum CurrentNetworkPath {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var value: NetworkPathSnapshot = .unknown

    /// The last path the monitor adopted. `.unknown` before it has started, which reads as
    /// satisfied and un-metered — the pre-monitor behaviour, deliberately.
    public static var current: NetworkPathSnapshot {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    /// Written only by `ConnectivityMonitor.apply`. Internal so nothing else can claim to
    /// know what the network is doing.
    static func set(_ snapshot: NetworkPathSnapshot) {
        lock.lock(); defer { lock.unlock() }
        value = snapshot
    }
}

/// Whether a path transition is the one worth acting on: the network just came back.
///
/// Pure and named because three separate recoveries key off it (re-attach in-flight jobs,
/// drain the send outbox, refresh the two cached documents) and "did we just come back"
/// must mean the same thing to all three. An interface SWAP — Wi-Fi to cellular, both
/// satisfied — is not a recovery: nothing was waiting, and treating it as one turns a walk
/// past the front door into a burst of refetches.
public func pathDidRecover(from old: NetworkPathSnapshot, to new: NetworkPathSnapshot) -> Bool {
    !old.isSatisfied && new.isSatisfied
}
