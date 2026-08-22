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
    func testAnUnreachableProbeBecomesReachableOnTheNextOne() async {
        let m = model()

        HealthProbeStubURLProtocol.isReachable = false
        m.refresh(config: cfg)
        await m.settled()
        XCTAssertEqual(m.state, .unreachable)
        XCTAssertTrue(shouldShowOfflineBanner(isConfigured: true, reachability: m.state))

        // The lid opens; the wake notification fires a second probe.
        HealthProbeStubURLProtocol.isReachable = true
        m.refresh(config: cfg)
        await m.settled()
        XCTAssertEqual(m.state, .reachable)
        XCTAssertFalse(shouldShowOfflineBanner(isConfigured: true, reachability: m.state),
                       "the banner must clear itself, not wait for a relaunch")
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
