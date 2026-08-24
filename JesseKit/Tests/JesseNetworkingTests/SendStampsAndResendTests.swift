import XCTest
@testable import JesseNetworking

/// A `URLProtocol` that can fail a chosen number of times before answering — the only way
/// to test "the socket dropped, did we re-send it, and did the re-send carry the same
/// idempotency key?" without a bridge.
final class FlakySendProtocol: URLProtocol {
    private struct Box: @unchecked Sendable {
        var bodies: [Data] = []
    }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var box = Box()
    /// How many attempts fail at the TRANSPORT level before one is answered.
    nonisolated(unsafe) static var failuresBeforeSuccess = 0
    /// The status the answered attempt carries.
    nonisolated(unsafe) static var status = 202
    nonisolated(unsafe) static var body = Data(#"{"job_id":"j1","status":"running"}"#.utf8)

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        box = Box()
        failuresBeforeSuccess = 0
        status = 202
        body = Data(#"{"job_id":"j1","status":"running"}"#.utf8)
    }

    static var bodies: [Data] {
        lock.lock(); defer { lock.unlock() }
        return box.bodies
    }

    static func session() -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [FlakySendProtocol.self]
        return URLSession(configuration: c)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        Self.lock.lock()
        if let data = request.httpBody {
            Self.box.bodies.append(data)
        } else if let stream = request.httpBodyStream {
            Self.box.bodies.append(Self.drain(stream))
        } else {
            Self.box.bodies.append(Data())
        }
        let shouldFail = Self.failuresBeforeSuccess > 0
        if shouldFail { Self.failuresBeforeSuccess -= 1 }
        let status = Self.status
        let body = Self.body
        Self.lock.unlock()

        guard !shouldFail else {
            // What a phone walking into a tunnel mid-POST actually produces.
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                       httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    private static func drain(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var out = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            out.append(contentsOf: buffer[0..<read])
        }
        return out
    }
}

/// The two things every `POST /jesse` now carries, and the one thing a dropped socket is
/// now allowed to do about it.
final class SendStampsAndResendTests: XCTestCase {

    private let config = JesseConfig(host: "studio", port: 8765, token: "tok")

    override func setUp() {
        super.setUp()
        FlakySendProtocol.reset()
    }

    private func client() -> JesseBridgeClient {
        JesseBridgeClient(config: config, session: FlakySendProtocol.session())
    }

    private func body(_ index: Int) throws -> [String: Any] {
        let data = try XCTUnwrap(FlakySendProtocol.bodies[safe: index])
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func request(id: String = "r1") -> JesseRequest {
        JesseRequest(mode: "tell", text: "a bowl of pasta", sessionId: nil,
                     conversationId: "c1", voice: false, instructions: nil,
                     floorOverride: nil, attachments: nil, healthContext: nil,
                     healthContextRequested: nil, healthContextUnavailable: nil,
                     mealCorrectionsAck: nil, requestId: id)
    }

    // MARK: - The stamps

    /// Both device stamps ride every turn, set by the CLIENT so there is no caller that
    /// can build a body without them.
    func testEveryTurnCarriesBothDeviceStamps() async throws {
        let request = request()
        XCTAssertNil(request.clientTz, "the value type carries neither until it is stamped")
        XCTAssertNil(request.sentAt)

        _ = try? await client().sendPrepared(request)
        let sent = try body(0)
        XCTAssertEqual(sent["client_tz"] as? String, TimeZone.current.identifier)
        XCTAssertNotNil(sent["sent_at"] as? String)
    }

    /// `sent_at` is RFC3339 with the DEVICE's offset, not UTC. The offset is the
    /// load-bearing half: the bridge derives a diet day from it minus four hours in the
    /// effective zone, and an offset-less instant makes no statement about which clock the
    /// person was reading.
    func testSentAtIsRFC3339WithTheDeviceOffset() throws {
        let stamp = JesseBridgeClient.sentAtStamp(Date(timeIntervalSince1970: 1_772_530_200))
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime]
        XCTAssertNotNil(parser.date(from: stamp), "not parseable as RFC3339: \(stamp)")
        // Either a `Z` (the device really is on UTC) or a `±HH:MM` with the colon RFC3339
        // requires. Never a bare `±HHMM`.
        let tail = String(stamp.suffix(6))
        XCTAssertTrue(stamp.hasSuffix("Z") || tail.contains(":"), "offset has no colon: \(stamp)")
    }

    /// One stamp for the whole send, including its re-send. That is the entire point of
    /// the field: a turn that waited for a tunnel to end must not be dated from the far
    /// side of the tunnel.
    func testAResendReusesTheSameSentAt() async throws {
        FlakySendProtocol.failuresBeforeSuccess = 1
        _ = try? await client().sendPrepared(request())
        XCTAssertEqual(FlakySendProtocol.bodies.count, 2)
        XCTAssertEqual(try body(0)["sent_at"] as? String, try body(1)["sent_at"] as? String)
    }

    // MARK: - The re-send

    /// A transport failure is ambiguous in the one way that matters — the body may already
    /// have reached the bridge. Retrying is safe BY CONSTRUCTION: the same `request_id`
    /// goes back, the bridge dedups on it, and a re-send of a POST that landed returns the
    /// same job with no second turn spawned.
    func testATransportFailureIsResentWithTheSameRequestId() async throws {
        FlakySendProtocol.failuresBeforeSuccess = 1
        let result = try await client().sendPrepared(request(id: "same-key"))
        guard case .running(let jobId, _) = result else {
            return XCTFail("expected a 202, got \(result)")
        }
        XCTAssertEqual(jobId, "j1")
        XCTAssertEqual(FlakySendProtocol.bodies.count, 2, "exactly one retry")
        XCTAssertEqual(try body(0)["request_id"] as? String, "same-key")
        XCTAssertEqual(try body(1)["request_id"] as? String, "same-key",
                       "a retry on a DIFFERENT key would defeat the bridge's dedup and "
                       + "duplicate the turn — which is the one thing this must not do")
    }

    /// One retry, not a loop. Past that the send outbox owns it, on a schedule measured in
    /// minutes rather than in socket timeouts.
    func testItRetriesExactlyOnce() async throws {
        FlakySendProtocol.failuresBeforeSuccess = 5
        do {
            _ = try await client().sendPrepared(request())
            XCTFail("expected the second failure to surface")
        } catch {
            XCTAssertTrue(error is JesseError, "\(error)")
        }
        XCTAssertEqual(FlakySendProtocol.bodies.count, 2)
    }

    /// A bridge that ANSWERED is not retried. A 401, a 429, a 413 — each is a request the
    /// bridge understood and refused, and re-sending it repeats a refusal.
    func testAnAnsweredRefusalIsNotResent() async throws {
        FlakySendProtocol.status = 401
        FlakySendProtocol.body = Data("no".utf8)
        _ = try? await client().sendPrepared(request())
        XCTAssertEqual(FlakySendProtocol.bodies.count, 1)
    }

    /// The resendable set, stated directly. ATS is in the NOT-resendable half on purpose:
    /// the bytes never left the device and never will, so a retry is a second identical
    /// local refusal.
    func testResendableErrorTable() {
        let withKey = request(id: "r1")
        for error in [JesseError.cannotFindHost("h"), .cannotConnect("h"), .timedOut("h"),
                      .connectionLost, .transport("x")] {
            XCTAssertTrue(JesseBridgeClient.isResendable(error, request: withKey), "\(error)")
        }
        for error in [JesseError.insecureBlocked("h"), .notConfigured,
                      .badResponse(429, "slow down"), .decoding] {
            XCTAssertFalse(JesseBridgeClient.isResendable(error, request: withKey), "\(error)")
        }
    }

    /// A request with no idempotency key is never retried: there is no such caller today,
    /// and if one ever appears a duplicate turn is worse than a surfaced error.
    func testARequestWithNoIdempotencyKeyIsNeverResent() {
        let bare = JesseRequest(mode: "ask", text: "hi", sessionId: nil, conversationId: "c1",
                                voice: false, instructions: nil, floorOverride: nil,
                                attachments: nil, healthContext: nil,
                                healthContextRequested: nil, healthContextUnavailable: nil,
                                mealCorrectionsAck: nil, requestId: nil)
        XCTAssertFalse(JesseBridgeClient.isResendable(.connectionLost, request: bare))
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
