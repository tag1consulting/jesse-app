import XCTest
import JesseNetworking
@testable import JesseOps

// What goes ON THE WIRE, driven through a `URLProtocol` stub rather than asserted about types.
//
// The routing test is the reason this file exists. "Fire and enable go through the sentinel
// when one is paired" is a claim about which HOST AND PORT a request reaches, and the only way
// to prove it is to let the request happen and read the URL. Asserting on `type(of:)` would
// pass just as happily against a client that built the right object and then called the wrong
// endpoint on it.

// MARK: - The stub

/// Captures every request and answers each with a canned 200. `URLProtocol` subclasses are
/// instantiated by the loading system, so the capture has to be static; the lock keeps that
/// honest under Swift 6's concurrency checking.
final class CapturingProtocol: URLProtocol, @unchecked Sendable {
    private struct Box: @unchecked Sendable {
        var requests: [URLRequest] = []
        var bodies: [Data] = []
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var box = Box()
    /// The status every stubbed answer carries. 200 unless a test wants a refusal.
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var body = Data("{}".utf8)

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        box = Box()
        status = 200
        body = Data("{}".utf8)
    }

    static var requests: [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return box.requests
    }

    static var bodies: [Data] {
        lock.lock(); defer { lock.unlock() }
        return box.bodies
    }

    /// The session a client under test is built on.
    static func session() -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [CapturingProtocol.self]
        return URLSession(configuration: c)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.box.requests.append(request)
        // `URLProtocol` strips `httpBody` off the request it hands the loader when the body was
        // set as a stream, so take whichever of the two is present. Without this the body
        // assertions below silently pass on an empty Data.
        if let body = request.httpBody {
            Self.box.bodies.append(body)
        } else if let stream = request.httpBodyStream {
            Self.box.bodies.append(CapturingProtocol.drain(stream))
        } else {
            Self.box.bodies.append(Data())
        }
        let status = Self.status
        let body = Self.body
        Self.lock.unlock()

        let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                       httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func drain(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var out = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            out.append(buffer, count: read)
        }
        return out
    }
}

// MARK: - Routing

final class OpsRoutingTests: XCTestCase {

    private let bridge = JesseConfig(host: "studio.tailnet.ts.net", port: 8765, token: "b-tok")
    private let sentinel = SentinelConfig(host: "studio.tailnet.ts.net", port: 8766,
                                          token: "s-tok")

    override func setUp() {
        super.setUp()
        CapturingProtocol.reset()
    }

    /// With NO sentinel paired, both verbs go straight to the bridge, on the bridge's port and
    /// under the bridge's token — byte for byte what the app did before this screen existed.
    func testWithoutASentinelTheVerbsGoToTheBridge() async throws {
        let config = OpsConfiguration(bridge: bridge,
                                      sentinel: SentinelConfig(host: "", token: ""))
        XCTAssertEqual(config.scheduleControlRoute, .bridge)
        XCTAssertNil(config.sentinelClient)

        let client = JesseBridgeClient(config: bridge, session: CapturingProtocol.session())
        _ = try await client.fireJob(id: "overnight", force: true)
        _ = try await client.enableJob(id: "overnight", enabled: false, until: nil)

        let urls = CapturingProtocol.requests.compactMap(\.url)
        XCTAssertEqual(urls.map(\.path),
                       ["/jesse/schedule/overnight/fire", "/jesse/schedule/overnight/enable"])
        XCTAssertEqual(urls.map(\.port), [8765, 8765])
        XCTAssertEqual(CapturingProtocol.requests.map { $0.value(forHTTPHeaderField: "Authorization") },
                       ["Bearer b-tok", "Bearer b-tok"])
    }

    /// With a sentinel paired, the SAME two calls reach the sentinel's own port, under the
    /// sentinel's own token, on the proxy routes.
    func testWithASentinelTheVerbsGoThroughIt() async throws {
        let config = OpsConfiguration(bridge: bridge, sentinel: sentinel)
        XCTAssertEqual(config.scheduleControlRoute, .sentinel)
        XCTAssertNotNil(config.sentinelClient)

        let client = SentinelClient(config: sentinel, session: CapturingProtocol.session())
        _ = try await client.fireJob(id: "overnight", force: false)
        _ = try await client.enableJob(id: "overnight", enabled: true, until: nil)

        let urls = CapturingProtocol.requests.compactMap(\.url)
        XCTAssertEqual(urls.map(\.path),
                       ["/sentinel/jobs/overnight/fire", "/sentinel/jobs/overnight/enable"])
        XCTAssertEqual(urls.map(\.port), [8766, 8766])
        XCTAssertEqual(CapturingProtocol.requests.map { $0.value(forHTTPHeaderField: "Authorization") },
                       ["Bearer s-tok", "Bearer s-tok"])
    }

    /// The two bodies both processes take. `until` OMITS when nil, which the bridge reads as
    /// "until it is changed"; sending an explicit null would be the same, but sending the key
    /// at all when there is no deadline invites a client to send `""`.
    func testTheVerbBodies() async throws {
        let client = SentinelClient(config: sentinel, session: CapturingProtocol.session())
        _ = try await client.fireJob(id: "overnight", force: true)
        _ = try await client.enableJob(id: "overnight", enabled: false,
                                       until: Date(timeIntervalSince1970: 1_772_530_200))

        let bodies = CapturingProtocol.bodies.map { String(data: $0, encoding: .utf8) ?? "" }
        XCTAssertEqual(bodies[0], #"{"force":true}"#)
        XCTAssertEqual(bodies[1], #"{"enabled":false,"until":"2026-03-03T09:30:00Z"}"#)
    }

    /// A refusal reaches the caller with the REASON, not a bare status. This is the `409` the
    /// Schedule screen prints on the row: "the chain headed by X is already running" is the
    /// whole answer, and losing it would leave a red row saying nothing.
    func testAConflictCarriesTheReasonThrough() async throws {
        CapturingProtocol.status = 409
        CapturingProtocol.body = Data(#"{"error":"another sentinel verb is already running"}"#.utf8)
        let client = SentinelClient(config: sentinel, session: CapturingProtocol.session())

        do {
            _ = try await client.fireJob(id: "overnight", force: false)
            XCTFail("a 409 must throw")
        } catch let error as JesseError {
            guard case .badResponse(let code, let text) = error else {
                return XCTFail("expected badResponse, got \(error)")
            }
            XCTAssertEqual(code, 409)
            XCTAssertEqual(text, "another sentinel verb is already running")
        }
    }

    /// The bridge's own errors are BARE TEXT, not JSON. Both shapes have to survive the same
    /// path, because which one arrives depends on whether a sentinel is paired.
    func testABareTextErrorFromTheBridgeSurvives() async throws {
        CapturingProtocol.status = 409
        CapturingProtocol.body = Data(#"the chain headed by "overnight" is already running"#.utf8)
        let client = JesseBridgeClient(config: bridge, session: CapturingProtocol.session())

        do {
            _ = try await client.fireJob(id: "overnight", force: false)
            XCTFail("a 409 must throw")
        } catch let error as JesseError {
            guard case .badResponse(_, let text) = error else {
                return XCTFail("expected badResponse, got \(error)")
            }
            XCTAssertEqual(text, #"the chain headed by "overnight" is already running"#)
        }
    }

    /// An unconfigured client sends NOTHING. A verb screen opened before pairing must not
    /// produce a request to port 8766 on an empty host.
    func testAnUnconfiguredSentinelSendsNothing() async {
        let client = SentinelClient(config: SentinelConfig(host: "", token: ""),
                                    session: CapturingProtocol.session())
        do {
            _ = try await client.status()
            XCTFail("an unconfigured client must throw")
        } catch {
            guard case .notConfigured? = error as? JesseError else {
                return XCTFail("expected notConfigured, got \(error)")
            }
        }
        XCTAssertTrue(CapturingProtocol.requests.isEmpty)
    }
}

// MARK: - Pairing

final class SentinelPairingTests: XCTestCase {

    /// The bridge appends `shost`/`sport`/`stoken` only when a sentinel is configured. Both
    /// halves come out of ONE scan, because they have to be saved together.
    func testAPayloadWithTheSentinelKeysYieldsBoth() throws {
        let raw = "jesse://pair?host=100.64.0.1&port=8765&token=deadbeef"
            + "&shost=100.64.0.1&sport=8766&stoken=s3nt"
        let payload = try XCTUnwrap(PairingPayload.parse(raw))

        XCTAssertEqual(payload.bridge.host, "100.64.0.1")
        XCTAssertEqual(payload.bridge.port, 8765)
        XCTAssertEqual(payload.bridge.token, "deadbeef")
        XCTAssertEqual(payload.sentinel?.host, "100.64.0.1")
        XCTAssertEqual(payload.sentinel?.port, 8766)
        XCTAssertEqual(payload.sentinel?.token, "s3nt")
    }

    /// A bridge with no sentinel is an ordinary, supported deployment. Its QR pairs the bridge
    /// exactly as it always did, and says NOTHING about the sentinel — which is not the same as
    /// saying there is none.
    func testABridgeOnlyPayloadYieldsNoSentinelHalf() throws {
        let payload = try XCTUnwrap(
            PairingPayload.parse("jesse://pair?host=studio&port=8765&token=deadbeef"))
        XCTAssertEqual(payload.bridge.token, "deadbeef")
        XCTAssertNil(payload.sentinel)
    }

    /// THE RULE THAT MATTERS: scanning a bridge-only QR must leave a sentinel this device
    /// already has alone. The parse returning nil is what the save path keys off — see
    /// `applyPairing` in each app's config store.
    func testABridgeOnlyPayloadLeavesAnExistingSentinelUntouched() throws {
        var stored = SentinelConfig(host: "studio", port: 8766, token: "s3nt")
        let payload = try XCTUnwrap(
            PairingPayload.parse("jesse://pair?host=studio&port=8765&token=newtoken"))
        if let fresh = payload.sentinel { stored = fresh }

        XCTAssertEqual(stored.token, "s3nt", "nothing in that payload was about the sentinel")
    }

    /// Half a sentinel is worse than none: a host with no token pairs a screen that 401s on
    /// every call.
    func testAHalfFilledSentinelIsRefused() throws {
        let payload = try XCTUnwrap(
            PairingPayload.parse("jesse://pair?host=studio&token=deadbeef&shost=studio&sport=8766"))
        XCTAssertNil(payload.sentinel)
    }

    /// An absent `sport` falls back to the sentinel's default, one above the bridge's.
    func testAMissingSentinelPortDefaults() throws {
        let payload = try XCTUnwrap(
            PairingPayload.parse("jesse://pair?host=studio&token=t&shost=studio&stoken=s"))
        XCTAssertEqual(payload.sentinel?.port, SentinelConfig.defaultPort)
        XCTAssertEqual(SentinelConfig.defaultPort, 8766)
    }

    /// A payload that is not a pairing URL at all yields nothing — including its sentinel half,
    /// which must never be taken from a link the bridge half rejected.
    func testGarbageYieldsNothing() {
        XCTAssertNil(PairingPayload.parse("https://example.com/?shost=evil&stoken=evil"))
        XCTAssertNil(PairingPayload.parse("jesse://pair?shost=evil&stoken=evil"))
    }

    /// Percent-encoded values survive the round trip — the bridge encodes both host and token.
    func testPercentEncodedValuesDecode() throws {
        let payload = try XCTUnwrap(
            PairingPayload.parse("jesse://pair?host=a%20b&token=t%26k&shost=c%20d&stoken=s%26k"))
        XCTAssertEqual(payload.bridge.token, "t&k")
        XCTAssertEqual(payload.sentinel?.host, "c d")
        XCTAssertEqual(payload.sentinel?.token, "s&k")
    }

    /// The sentinel's own URL building reuses the bridge's host sanitizer, so a pasted
    /// `host:port` behaves the same in both fields.
    func testTheSentinelSanitizesAPastedHost() {
        let cfg = SentinelConfig(host: "http://Studio.tailnet.ts.net:9000/x", port: 8766,
                                 token: "t")
        XCTAssertEqual(cfg.normalizedHost, "studio.tailnet.ts.net")
        XCTAssertEqual(cfg.effectivePort, 9000)
        XCTAssertEqual(cfg.endpoint("/sentinel/status")?.absoluteString,
                       "http://studio.tailnet.ts.net:9000/sentinel/status")
    }
}

// MARK: - client_tz

/// `client_tz` on every request type that carries it.
///
/// The bridge lets it OUTRANK the away profile for that one request, because the phone's own
/// zone is a more specific claim than a fortnight-long declaration. That only works if the app
/// actually sends it, on the reads as well as the writes — which day a diet request answers for
/// depends on it.
final class ClientTimeZoneWireTests: XCTestCase {

    private let config = JesseConfig(host: "studio", port: 8765, token: "tok")

    override func setUp() {
        super.setUp()
        CapturingProtocol.reset()
    }

    private func client() -> JesseBridgeClient {
        JesseBridgeClient(config: config, session: CapturingProtocol.session())
    }

    private func lastBody() throws -> [String: Any] {
        let data = try XCTUnwrap(CapturingProtocol.bodies.last)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// Every `POST /jesse` body, including the health-laden one the iOS layer builds and hands
    /// to `sendPrepared` directly. Stamped by the CLIENT, so there is no caller that can omit it.
    func testEveryTurnCarriesTheDeviceZone() async throws {
        CapturingProtocol.body = Data(#"{"job_id":"j1","conversation_id":"c1"}"#.utf8)
        let request = JesseRequest(mode: "ask", text: "hi", sessionId: nil,
                                   conversationId: "c1", voice: false, instructions: nil,
                                   floorOverride: nil, attachments: nil, healthContext: "…",
                                   healthContextRequested: nil, healthContextUnavailable: nil,
                                   mealCorrectionsAck: nil, requestId: "r1")
        XCTAssertNil(request.clientTz, "the value type carries none until the client stamps it")

        _ = try? await client().sendPrepared(request)
        XCTAssertEqual(try lastBody()["client_tz"] as? String, TimeZone.current.identifier)
    }

    func testTheDayFileReadCarriesItAsAQueryItem() async throws {
        CapturingProtocol.body = Data("{}".utf8)
        _ = try? await client().getToday()

        let url = try XCTUnwrap(CapturingProtocol.requests.last?.url)
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.first { $0.name == "client_tz" }?.value,
                       TimeZone.current.identifier)
    }

    /// …and the diet read, where it decides WHICH DAY is answered for: a diet day starts at
    /// 04:00 in the zone the eater is standing in.
    func testTheDietReadCarriesItAlongsideAnyDate() async throws {
        CapturingProtocol.body = Data("{}".utf8)
        _ = try? await client().fetchDietSnapshot(date: "2026-08-24")

        let url = try XCTUnwrap(CapturingProtocol.requests.last?.url)
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.first { $0.name == "date" }?.value, "2026-08-24")
        XCTAssertEqual(items.first { $0.name == "client_tz" }?.value,
                       TimeZone.current.identifier)
    }

    /// The three day-file writes. `check` and `move` stamp a DATE into `Today.md`, so the zone
    /// is what decides which day a tick made abroad lands on.
    func testTheDayFileWritesCarryIt() async throws {
        CapturingProtocol.body = Data("{}".utf8)
        let c = client()
        _ = try? await c.checkItem(id: "abc", checked: true, evidence: nil, at: Date(),
                                   day: nil, ifMatch: "\"etag\"")
        XCTAssertEqual(try lastBody()["client_tz"] as? String, TimeZone.current.identifier)

        _ = try? await c.moveItem(id: "abc", op: .toDoNow, at: Date(), day: nil,
                                  ifMatch: "\"etag\"")
        XCTAssertEqual(try lastBody()["client_tz"] as? String, TimeZone.current.identifier)

        _ = try? await c.postpone(id: "abc", deferred: true, at: Date(), day: nil,
                                  ifMatch: "\"etag\"")
        XCTAssertEqual(try lastBody()["client_tz"] as? String, TimeZone.current.identifier)
    }

    /// `POST /jesse/today/glance` is the ONE write with no such field on the bridge
    /// (`GlanceBody` has no `client_tz`), and the app must not invent one: a glance writes
    /// nothing to the vault and derives no date.
    func testTheGlanceWriteDoesNotCarryIt() async throws {
        CapturingProtocol.body = Data("{}".utf8)
        _ = try? await client().glance(id: "abc", at: Date(), ifMatch: "\"etag\"")
        XCTAssertNil(try lastBody()["client_tz"])
    }
}
