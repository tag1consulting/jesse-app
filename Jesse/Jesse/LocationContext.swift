import Foundation

// The Foundation-only half of the location channel: the provider seam, the resolver the
// send path attaches through, and the shared device-context fulfilment protocol both
// channels answer their directives through. CoreLocation itself lives behind
// `LocationContextProviding` in `LocationContextProvider.swift`, and nothing in this
// file imports it — which is what lets every policy decision here be unit-tested on a
// simulator that has no fix.

// MARK: - Provider seam

/// The one seam CoreLocation hides behind. A conformer returns a best-effort
/// `LocationReading`. It **never throws and never blocks a send**: every degrade path —
/// permission denied, Location Services off, the fix timing out, a device with no fix,
/// a simulator with no location set — yields an empty reading, so a turn always goes
/// out (just without the block). `LocationContextProvider` is the sole production
/// conformer; tests inject a fake.
///
/// Deliberately narrower than `HealthContextProviding`: there is one read, not a
/// snapshot plus a windowed series, because a location has no history to window over.
protocol LocationContextProviding: Sendable {
    /// The live authorization state, read fresh at the moment of asking, and split
    /// three ways rather than two.
    ///
    /// The split is the whole point: "Location Services are off for the device" and
    /// "this app is not allowed to use them" look identical from a Bool and are
    /// completely different things to tell the owner — one is a device-wide switch in
    /// Settings › Privacy, the other is this app's own row. Conflating them is how a
    /// reader is sent to the wrong toggle.
    ///
    /// `.notDetermined` reports `.unauthorized`, deliberately: the app has never asked,
    /// and asking here — inside a turn, because of a message he typed — is exactly the
    /// mid-turn ambush the gate exists to prevent. Read separately from `reading` so
    /// the gate can refuse BEFORE anything touches the location manager.
    func authorizationState() async -> LocationAuthorizationState

    /// One best-effort reading. `precision` selects reduced vs full accuracy;
    /// `maxAgeSeconds` is how stale a cached fix may be before a fresh one is taken (0
    /// forces a fresh reading). `wantsPlacemark` gates the reverse geocode, which is a
    /// network round trip and is skipped when the request did not ask for a placemark.
    /// `budget` is what THIS call may spend — see `LocationFixBudget`, and note that it
    /// is a per-call value precisely because the proactive attach and the directive
    /// fulfilment cannot share one.
    ///
    /// Never throws and never blocks a send: a failure comes back as an empty reading
    /// plus the reason it was empty, which the caller puts on the wire.
    func reading(precision: LocationPrecision,
                 maxAgeSeconds: Int,
                 wantsPlacemark: Bool,
                 budget: LocationFixBudget) async -> LocationReadingResult
}

extension LocationContextProviding {
    /// The Bool the gate and the resolver want. True ONLY for when-in-use authorization
    /// with Location Services on.
    func isAuthorized() async -> Bool {
        await authorizationState() == .authorized
    }
}

/// The three states the gate distinguishes, which is one more than a Bool can carry.
nonisolated enum LocationAuthorizationState: Sendable, Equatable {
    /// When-in-use, with Location Services on. The only state that reads anything.
    case authorized
    /// Location Services are off for the entire device.
    case servicesOff
    /// Services are on, but this app may not use them — denied, restricted, or never
    /// asked.
    case unauthorized

    /// The wire reason this state produces when a request cannot be fulfilled.
    var unavailableReason: LocationUnavailableReason? {
        switch self {
        case .authorized: return nil
        case .servicesOff: return .servicesOff
        case .unauthorized: return .unauthorized
        }
    }
}

/// A reading plus, when it is empty, WHY it is empty.
///
/// The reason is carried out of the provider rather than derived by the caller because
/// only the provider knows which of "the deadline expired", "the phone could not place
/// itself" and "the permission is gone" happened. Losing that distinction at this seam
/// is what left the bridge telling the agent all four causes at once.
nonisolated struct LocationReadingResult: Sendable, Equatable {
    var reading: LocationReading
    /// Nil exactly when `reading` carries something renderable.
    var reason: LocationUnavailableReason?

    static func got(_ reading: LocationReading) -> Self {
        LocationReadingResult(reading: reading, reason: nil)
    }

    static func unavailable(_ reason: LocationUnavailableReason) -> Self {
        LocationReadingResult(reading: .empty, reason: reason)
    }
}

// MARK: - The shared fulfilment seam

/// What a device-context channel needs to answer its own directive: whether it is
/// switched on at all, and how to turn a validated request into a block.
///
/// This exists so `JesseClient.fulfill` is written ONCE. The two channels differ in
/// their request type, their consent checks and their provider — and in nothing about
/// the shape of the answer, which is "a block, or nothing". Writing that twice is how
/// the second copy quietly loses the `unavailable` terminator and the retry loops.
protocol DeviceContextFulfilling: Sendable {
    /// The channel's validated request type (`NeedsHealthRequest`, `NeedsLocationRequest`).
    associatedtype Request: Sendable

    /// Whether this channel may run at all right now — the master toggle, plus any
    /// live system consent the channel depends on. Not-ready short-circuits `fulfill`
    /// BEFORE the provider is touched, so a switched-off channel never prompts.
    func mayFulfill() async -> DeviceContextReadiness

    /// The block answering `request`, or the reason nothing could be gathered.
    func block(for request: Request) async -> DeviceContextOutcome
}

/// Whether a channel may run, and if not, why not.
///
/// The reason is a wire STRING rather than a channel-specific enum because this protocol
/// is shared and the vocabulary is not: location has five reasons the bridge renders
/// separately, health has none yet and passes nil. A channel with no vocabulary carries
/// no reason and the bridge falls back to its generic line, which is exactly today's
/// behaviour for that channel.
nonisolated enum DeviceContextReadiness: Sendable, Equatable {
    case ready
    case notReady(String?)
}

/// The result of trying to gather one channel's block: the block, or the reason there
/// is none. Never both.
nonisolated struct DeviceContextOutcome: Sendable, Equatable {
    var block: String?
    var reason: String?

    static func gathered(_ block: String) -> Self {
        DeviceContextOutcome(block: block, reason: nil)
    }

    static func nothing(_ reason: String?) -> Self {
        DeviceContextOutcome(block: nil, reason: reason)
    }
}

/// Fulfil one channel's request through its `DeviceContextFulfilling`, honouring the
/// channel's consent. The single implementation of the fulfil policy, for every
/// channel: off or unauthorized → unavailable, nothing gathered → unavailable, a block
/// → fulfilled. There is no fourth outcome, and in particular there is no path that
/// returns "no block and no flag" — that shape is an ordinary turn, and sending it as a
/// retry would put the agent back on the request instruction and loop the channel.
func fulfillDeviceContext<F: DeviceContextFulfilling>(
    _ request: F.Request, through channel: F
) async -> OutgoingDeviceContext {
    if case .notReady(let reason) = await channel.mayFulfill() {
        return .unavailable(reason: reason)
    }
    let outcome = await channel.block(for: request)
    guard let block = outcome.block, !block.isEmpty else {
        return .unavailable(reason: outcome.reason)
    }
    return .fulfilled(block)
}

// MARK: - The two concrete channels

/// The health channel's fulfiller: the master health toggle, and the provider's
/// snapshot + per-metric series assembled by `HealthRequestFulfiller`.
nonisolated struct HealthChannel: DeviceContextFulfilling {
    let provider: any HealthContextProviding
    /// The master toggle, injected so the policy is testable without `UserDefaults`.
    let enabled: @Sendable () -> Bool

    init(provider: any HealthContextProviding,
         enabled: @escaping @Sendable () -> Bool = { HealthContextSettings.isEnabled }) {
        self.provider = provider
        self.enabled = enabled
    }

    /// Health carries no reason vocabulary yet — HealthKit hides read denials by
    /// design, so the app genuinely cannot tell "denied" from "no data". Passing nil
    /// keeps the bridge on its existing generic health line, byte for byte.
    func mayFulfill() async -> DeviceContextReadiness {
        enabled() ? .ready : .notReady(nil)
    }

    func block(for request: NeedsHealthRequest) async -> DeviceContextOutcome {
        let snapshot = request.sections.isEmpty ? HealthSnapshot.empty : await provider.snapshot()
        var series: [RequestableMetric: [MetricSeriesPoint]] = [:]
        for m in request.metrics {
            series[m.metric] = await provider.series(for: m.metric, windowDays: m.windowDays)
        }
        let block = HealthRequestFulfiller.block(request: request, snapshot: snapshot,
                                                 series: series, now: Date())
        return DeviceContextOutcome(block: block, reason: nil)
    }
}

/// The location channel's fulfiller: the master location toggle AND the live
/// CoreLocation authorization, then one reading rendered by `LocationRequestFulfiller`.
///
/// `mayFulfill` checks BOTH consents before the provider is touched. That ordering is
/// the whole reason a denied permission produces an answer instead of a prompt: the
/// location manager is never asked for anything, so there is nothing for the system to
/// prompt about, and the caller gets `.unavailable` immediately.
nonisolated struct LocationChannel: DeviceContextFulfilling {
    let provider: any LocationContextProviding
    let enabled: @Sendable () -> Bool

    init(provider: any LocationContextProviding,
         enabled: @escaping @Sendable () -> Bool = { LocationContextSettings.isEnabled }) {
        self.provider = provider
        self.enabled = enabled
    }

    /// Both consents, each reported as its OWN reason. The ordering is what stops a
    /// denied permission producing a prompt: the location manager is never asked for
    /// anything, so there is nothing for the system to prompt about.
    func mayFulfill() async -> DeviceContextReadiness {
        guard enabled() else {
            return .notReady(LocationUnavailableReason.featureOff.rawValue)
        }
        let state = await provider.authorizationState()
        guard LocationContextGate.mayFulfill(enabled: true,
                                             authorized: state == .authorized) else {
            return .notReady(state.unavailableReason?.rawValue)
        }
        return .ready
    }

    /// THE FULFILMENT BUDGET, and the reason it is not the proactive one.
    ///
    /// This runs as a retry BETWEEN two turns: the agent has already asked for a
    /// location and is waiting to answer. The owner is watching a spinner either way,
    /// so several extra seconds here are invisible — unlike the proactive attach in
    /// `LocationContextResolver.resolve`, which sits between his pressing send and the
    /// message leaving the phone. This is also the path that asks for precise fixes, and
    /// the path that was failing on all of them.
    ///
    /// **These two budgets must stay different.** One shared timeout, reasoned about for
    /// the send path and inherited by this one, is the bug.
    func block(for request: NeedsLocationRequest) async -> DeviceContextOutcome {
        let result = await provider.reading(
            precision: request.precision,
            maxAgeSeconds: request.maxAgeSeconds,
            wantsPlacemark: request.fields.contains(.placemark),
            budget: .fulfilment)
        guard let block = LocationRequestFulfiller.block(request: request,
                                                         reading: result.reading,
                                                         now: Date()) else {
            // A reading that produced no renderable line is the timed-out shape when the
            // provider did not say otherwise.
            return .nothing((result.reason ?? .timedOut).rawValue)
        }
        return .gathered(block)
    }
}

// MARK: - Resolver (send-path wiring)

/// Resolves the `location_context` string a PROACTIVE turn should carry, or nil to
/// attach nothing. Applied inside `JesseClient.send` so every turn path — typed, Siri,
/// and the watch relay — inherits it.
///
/// The proactive attach is deliberately the most conservative request the channel can
/// make: a `placemark` at `coarse` precision, from a fix up to five minutes old. The
/// agent has not asked for anything at this point — the classifier merely guessed the
/// turn might want it — so the attach spends the least it can and never triggers the
/// full-accuracy prompt. When coarse is not enough, the agent says so with a directive
/// and the retry path serves exactly what it asked for.
///
/// Pure given the provider, so it is unit-tested with a fake and a fixed clock.
nonisolated enum LocationContextResolver {
    /// The proactive attach's standing request. Not a `precise` one, and not a
    /// coordinates one: see above.
    static let proactiveRequest = NeedsLocationRequest(
        fields: [.placemark, .accuracy], precision: .coarse, maxAgeSeconds: 300)

    static func resolve(enabled: Bool,
                        relevant: Bool,
                        provider: any LocationContextProviding,
                        now: Date = Date()) async -> String? {
        // The toggle and the classifier are cheap and local; the authorization read is
        // cheap too but touches CoreLocation, so it is checked last and only when the
        // first two already say yes.
        guard enabled, relevant else { return nil }
        guard await provider.isAuthorized() else { return nil }
        guard LocationContextGate.shouldAttach(enabled: enabled, authorized: true,
                                               relevant: relevant) else { return nil }
        // THE PROACTIVE BUDGET, and the reason it is not the fulfilment one. This cost
        // sits between the owner pressing send and the message leaving the phone, so it
        // stays tight — and the request it pays for is the cheap one (coarse, five
        // minutes of staleness allowed), which is usually served from cache or by a fast
        // reduced-accuracy fix and never reaches the deadline. `LocationChannel.block`
        // deliberately spends more; see the comment there.
        let result = await provider.reading(
            precision: proactiveRequest.precision,
            maxAgeSeconds: proactiveRequest.maxAgeSeconds,
            wantsPlacemark: true,
            budget: .proactive)
        return LocationRequestFulfiller.block(request: proactiveRequest,
                                              reading: result.reading, now: now)
    }
}
