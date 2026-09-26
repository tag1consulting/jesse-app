import XCTest
@testable import JesseNetworking

/// A `URLProtocol` that answers with a fixed `text/event-stream` body — enough to assert what
/// the SSE reader reports for each KIND of line, which is not something `SSEParser` can answer
/// on its own: the parser's contract is "a comment is not a frame", and the question here is
/// what the client does with the lines the parser declines.
final class StubSSEProtocol: URLProtocol {
    nonisolated(unsafe) static var body = Data()

    static func session() -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [StubSSEProtocol.self]
        return URLSession(configuration: c)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                   headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
}

/// **Where a dead stream is told apart from a quiet one.**
///
/// The bridge keeps an SSE connection warm with comment lines (axum's `KeepAlive::default()`,
/// a `:` line every 15 seconds) and `SSEParser` drops them, correctly — a comment is not an
/// event. The consequence was that a client watching only events could not tell a model
/// thinking for two minutes from a socket that had died without closing, and the Mac's run
/// state therefore stayed shut on a dead stream until the app was relaunched.
///
/// `streamItems` is the answer, and these pin it: a line that carries no frame is reported as
/// `alive`, the frames are unchanged, and `stream` — what the iOS app reads — still yields
/// frames only.
final class StreamLivenessTests: XCTestCase {

    private let config = JesseConfig(host: "studio", port: 8765, token: "tok")

    /// A keep-alive comment, one `delta` frame, another comment, then `done`.
    private let sse = """
    : keep-alive

    event: delta
    data: {"text":"hi"}

    : keep-alive

    event: done
    data: {"response":"hi there"}

    """

    override func setUp() {
        super.setUp()
        StubSSEProtocol.body = Data(sse.utf8)
    }

    private func client() -> JesseBridgeClient {
        JesseBridgeClient(config: config, session: StubSSEProtocol.session())
    }

    func testAKeepAliveCommentIsReportedAsLivenessAndNotAsAFrame() async throws {
        var items: [JesseStreamItem] = []
        for try await item in client().streamItems(jobId: "j1") { items.append(item) }

        guard case .alive = try XCTUnwrap(items.first) else {
            return XCTFail("the leading keep-alive comment must arrive as liveness, not be dropped")
        }
        let events = items.compactMap { item -> JesseStreamEvent? in
            if case let .event(ev) = item { return ev }
            return nil
        }
        XCTAssertEqual(events.count, 2, "and the two real frames are still frames")
        XCTAssertEqual(events.first, .delta("hi"))
        guard case let .done(reply) = try XCTUnwrap(events.last) else {
            return XCTFail("the terminal frame is a done")
        }
        XCTAssertEqual(reply.text, "hi there")
        XCTAssertTrue(items.count > events.count,
                      "liveness ticks arrive in addition to the frames, never instead of them")
    }

    /// The frame-only view is what the iOS app reads, and it must not start seeing liveness.
    func testTheFrameOnlyStreamYieldsNoLiveness() async throws {
        var events: [JesseStreamEvent] = []
        for try await ev in client().stream(jobId: "j1") { events.append(ev) }

        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events.first, .delta("hi"))
    }
}
