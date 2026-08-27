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
    /// The live CoreLocation authorization status, read fresh at the moment of asking.
    /// True ONLY for `.authorizedWhenInUse` — see `LocationContextGate` for why
    /// `.notDetermined` and `.authorizedAlways` are both excluded. Read separately from
    /// `reading` so the gate can refuse BEFORE anything touches the location manager,
    /// which is what stops a permission prompt appearing mid-turn.
    func isAuthorized() async -> Bool

    /// One best-effort reading. `precision` selects reduced vs full accuracy;
    /// `maxAgeSeconds` is how stale a cached fix may be before a fresh one is taken (0
    /// forces a fresh reading). `wantsPlacemark` gates the reverse geocode, which is a
    /// network round trip and is skipped when the request did not ask for a placemark.
    /// Returns `.empty` on ANY failure — the caller reads that as unfulfillable.
    func reading(precision: LocationPrecision,
                 maxAgeSeconds: Int,
                 wantsPlacemark: Bool) async -> LocationReading
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
    /// live system consent the channel depends on. False short-circuits `fulfill`
    /// BEFORE the provider is touched, so a switched-off channel never prompts.
    func mayFulfill() async -> Bool

    /// The block answering `request`, or nil when nothing could be gathered.
    func block(for request: Request) async -> String?
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
    guard await channel.mayFulfill() else { return .unavailable }
    guard let block = await channel.block(for: request), !block.isEmpty else {
        return .unavailable
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

    func mayFulfill() async -> Bool { enabled() }

    func block(for request: NeedsHealthRequest) async -> String? {
        let snapshot = request.sections.isEmpty ? HealthSnapshot.empty : await provider.snapshot()
        var series: [RequestableMetric: [MetricSeriesPoint]] = [:]
        for m in request.metrics {
            series[m.metric] = await provider.series(for: m.metric, windowDays: m.windowDays)
        }
        return HealthRequestFulfiller.block(request: request, snapshot: snapshot,
                                            series: series, now: Date())
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

    func mayFulfill() async -> Bool {
        LocationContextGate.mayFulfill(enabled: enabled(),
                                       authorized: await provider.isAuthorized())
    }

    func block(for request: NeedsLocationRequest) async -> String? {
        let reading = await provider.reading(
            precision: request.precision,
            maxAgeSeconds: request.maxAgeSeconds,
            wantsPlacemark: request.fields.contains(.placemark))
        return LocationRequestFulfiller.block(request: request, reading: reading, now: Date())
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
        let reading = await provider.reading(
            precision: proactiveRequest.precision,
            maxAgeSeconds: proactiveRequest.maxAgeSeconds,
            wantsPlacemark: true)
        return LocationRequestFulfiller.block(request: proactiveRequest,
                                              reading: reading, now: now)
    }
}
