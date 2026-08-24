import XCTest
@testable import JesseNetworking

// The reachability probe, which until this change existed only in the iOS target — so
// the Mac had no offline banner, no read-only day, and, worse, no way to notice it had
// come back after the lid was closed.
//
// The transition is driven through a real `URLSession` and a `URLProtocol` stub rather
// than by setting the flag by hand, because "unreachable → reachable without relaunching"
// is the whole behavior a woken laptop depends on and a hand-set flag would not test it.

/// `GET /health` answers, or refuses to connect, per test.
final class HealthProbeStubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var isReachable = false
    nonisolated(unsafe) static var probeCount = 0
    nonisolated(unsafe) static var isEnabled = false

    override class func canInit(with request: URLRequest) -> Bool { isEnabled }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        Self.probeCount += 1
        guard Self.isReachable, let url = request.url else {
            // What a sleeping Studio actually looks like from a woken laptop.
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let http = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                   headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"ok":true,"version":"0.89.0"}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    static func reset() {
        isReachable = false
        probeCount = 0
        isEnabled = false
    }
}

@MainActor
final class BridgeReachabilityProbeTests: XCTestCase {

    private let cfg = JesseConfig(host: "laptop", port: 8765, token: "tok")

    override func setUp() async throws {
        HealthProbeStubURLProtocol.reset()
        HealthProbeStubURLProtocol.isEnabled = true
    }

    override func tearDown() async throws {
        HealthProbeStubURLProtocol.reset()
    }

    private func model() -> BridgeReachabilityModel {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [HealthProbeStubURLProtocol.self]
        return BridgeReachabilityModel(session: URLSession(configuration: c))
    }

    /// The state a cold launch starts in. Deliberately not `unreachable`, so the banner
    /// never flashes before anything has actually been asked.
    func testTheStateBeforeAnyProbeIsUnknown() {
        XCTAssertEqual(model().state, .unknown)
        XCTAssertFalse(shouldShowOfflineBanner(isConfigured: true, reachability: .unknown))
    }

    /// **The woken-laptop case.** One probe fails (the Studio was asleep), the next
    /// succeeds, and the model moves back on its own — no relaunch, no manual refresh.
    ///
    /// The clock is passed explicitly because probes are now THROTTLED to one per
    /// `probeInterval`: a second probe a moment after the first would be skipped, which is
    /// the whole point of the throttle and is asserted separately below.
    func testAnUnreachableProbeBecomesReachableOnTheNextOne() async {
        let m = model()
        let t0 = Date(timeIntervalSince1970: 1_000_000)

        HealthProbeStubURLProtocol.isReachable = false
        m.refresh(config: cfg, now: t0)
        await m.settled()
        XCTAssertEqual(m.state, .unreachable)
        XCTAssertTrue(shouldShowOfflineBanner(isConfigured: true, reachability: m.state))

        // The lid opens; the wake notification fires a second probe.
        HealthProbeStubURLProtocol.isReachable = true
        m.refresh(config: cfg, now: t0.addingTimeInterval(BridgeReachabilityModel.probeInterval))
        await m.settled()
        XCTAssertEqual(m.state, .reachable)
        XCTAssertFalse(shouldShowOfflineBanner(isConfigured: true, reachability: m.state),
                       "the banner must clear itself, not wait for a relaunch")
    }

    // MARK: - The throttle

    /// Three tabs, a scene-phase change and a settings dismissal all ask for a refresh on
    /// one return to the app. Before the throttle that was five `GET /health` calls, every
    /// one of them answering the same thing.
    func testRepeatedRefreshesInsideTheIntervalProbeOnce() async {
        let m = model()
        HealthProbeStubURLProtocol.isReachable = true
        let t0 = Date(timeIntervalSince1970: 2_000_000)
        for offset in [0.0, 1.0, 5.0, 29.0] {
            m.refresh(config: cfg, now: t0.addingTimeInterval(offset))
            await m.settled()
        }
        XCTAssertEqual(HealthProbeStubURLProtocol.probeCount, 1)

        // Past the interval it probes again.
        m.refresh(config: cfg, now: t0.addingTimeInterval(31))
        await m.settled()
        XCTAssertEqual(HealthProbeStubURLProtocol.probeCount, 2)
    }

    /// `force` is for the two events that are real news rather than a repeated question: a
    /// re-pairing (a different bridge entirely) and the network coming back. In both the
    /// last answer is known to be about something else.
    func testForceBypassesTheThrottle() async {
        let m = model()
        HealthProbeStubURLProtocol.isReachable = true
        let t0 = Date(timeIntervalSince1970: 3_000_000)
        m.refresh(config: cfg, now: t0)
        await m.settled()
        m.refresh(config: cfg, force: true, now: t0.addingTimeInterval(1))
        await m.settled()
        XCTAssertEqual(HealthProbeStubURLProtocol.probeCount, 2)
    }

    // MARK: - Learning from real requests

    /// The cheap half of the whole feature: a real bridge call that answered is better
    /// evidence than a `GET /health` will ever be, so the app largely stops needing to
    /// probe at all.
    func testARealRequestOutcomeSetsTheStateAndCountsAsAProbe() async {
        let m = model()
        let t0 = Date(timeIntervalSince1970: 4_000_000)

        m.noteRequestOutcome(succeeded: false, now: t0)
        XCTAssertEqual(m.state, .unreachable)

        // It also satisfies the throttle — there is no point probing something we just
        // asked directly.
        HealthProbeStubURLProtocol.isReachable = true
        m.refresh(config: cfg, now: t0.addingTimeInterval(1))
        await m.settled()
        XCTAssertEqual(HealthProbeStubURLProtocol.probeCount, 0)
        XCTAssertEqual(m.state, .unreachable)

        m.noteRequestOutcome(succeeded: true, now: t0.addingTimeInterval(2))
        XCTAssertEqual(m.state, .reachable)
    }

    /// The network coming back re-probes by itself, forced past the throttle — which is
    /// what makes the offline banner clear without anyone switching tabs.
    func testFollowingTheMonitorReprobesOnRecovery() async {
        let m = model()
        let monitor = ConnectivityMonitor(source: DeadPathSource())
        m.follow(monitor) { self.cfg }
        defer { m.unfollow() }
        await Task.yield()

        HealthProbeStubURLProtocol.isReachable = true
        monitor.apply(NetworkPathSnapshot(isSatisfied: false, isExpensive: false,
                                          isConstrained: false, interfaceKind: .unknown))
        monitor.apply(NetworkPathSnapshot(isSatisfied: true, isExpensive: false,
                                          isConstrained: false, interfaceKind: .wifi))
        for _ in 0..<200 where HealthProbeStubURLProtocol.probeCount == 0 {
            try? await Task.sleep(for: .milliseconds(5))
        }
        await m.settled()
        XCTAssertEqual(HealthProbeStubURLProtocol.probeCount, 1)
        XCTAssertEqual(m.state, .reachable)
    }

    /// An UNPAIRED app is not offline, it is unconfigured — and the pairing screen, not
    /// the offline banner, is the answer to that. No probe is even sent.
    func testAnUnconfiguredAppIsUnknownAndProbesNothing() async {
        let m = model()
        m.refresh(config: JesseConfig(host: "", port: 8765, token: ""))
        await m.settled()

        XCTAssertEqual(m.state, .unknown)
        XCTAssertEqual(HealthProbeStubURLProtocol.probeCount, 0)
        XCTAssertFalse(shouldShowOfflineBanner(isConfigured: false, reachability: .unreachable))
    }

    /// A screen that has just completed a real round trip knows better than a probe from
    /// thirty seconds ago; `adopt` is how it says so.
    func testAdoptOverridesTheProbedState() async {
        let m = model()
        HealthProbeStubURLProtocol.isReachable = false
        m.refresh(config: cfg)
        await m.settled()
        XCTAssertEqual(m.state, .unreachable)

        m.adopt(.reachable)
        XCTAssertEqual(m.state, .reachable)
    }
}

/// A source that never yields — the monitor's own `apply` is what the test drives.
private struct DeadPathSource: NetworkPathSource {
    func paths() -> AsyncStream<NetworkPathSnapshot> {
        AsyncStream { _ in }
    }
}
