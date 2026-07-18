import XCTest
import SwiftData
@testable import Jesse

// Integration tests that drive the REAL `JesseClient` (and `RunCoordinator` with
// the real client, not the fake) against an in-process `URLProtocol` stub that
// serves the bridge's real wire shapes for POST /jesse, GET /jesse/result/{id},
// and GET /jesse/stream/{id}. This is the test layer the unit tests skipped: the
// fake-based `RunCoordinator*Tests` exercise coordinator *logic* but never touch
// `JesseClient`'s HTTP/SSE byte-level paths or the send→persist→consume wiring as
// it actually runs over a URLSession.
//
// The stub can model both the OLD bridge (POST holds a grace window before any
// job_id, and the connection can drop mid-hold) and the FIXED bridge (POST
// returns 202 with the job_id immediately). The orphan bug — and the fix — live
// in that difference: deliver the job_id late and a mid-hold drop orphans the
// turn; deliver it immediately and the turn is always recoverable.

// MARK: - URLProtocol stub bridge

/// One SSE frame the stub can emit on `GET /jesse/stream/{id}`.
enum StubFrame {
    case reset(String)
    case delta(String)
    case activity(String)
    case done(response: String, sessionId: String?)
    case error(String)
    case cancelled
}

/// What `GET /jesse/stream/{id}` does.
enum StubStreamBehavior {
    /// Emit the frames (with a small gap between) then close cleanly.
    case framesThenClose([StubFrame])
    /// Emit the frames (typically a `reset`/`delta`s — no terminal frame) then
    /// stall open forever: never a terminal frame, never a close (the half-open
    /// case). Only a teardown (consumer cancels) ends it.
    case framesThenStall([StubFrame])
    /// Fail the moment the stream is opened (transport error) — models a stream
    /// that won't even connect; the poll must still own completion.
    case failImmediately
    /// 404 — unknown/expired id when the stream is opened.
    case notFound
}

/// What `GET /jesse/result/{id}` returns on successive polls (the last entry
/// repeats once exhausted).
enum StubResult {
    case running
    case done(response: String, sessionId: String?)
    case failed(String)
    /// 404 — the bridge no longer has the job (past its TTL).
    case expired
    /// `{"status":"cancelled"}` — the turn was cancelled server-side.
    case cancelled
    /// The poll connection drops (recoverable transport error).
    case transportDrop
    /// The poll opens nothing and never finishes — models a bridge that went
    /// unreachable mid-turn (Mac asleep, half-open socket). Only a bounded
    /// per-request deadline (or a teardown) ends it. The result-endpoint twin of
    /// `framesThenStall`.
    case stalledResult
}

/// What `POST /jesse` does.
enum StubPost {
    /// The fixed bridge: hand back `202 {job_id,status:running}` immediately.
    case immediate202(jobId: String)
    /// The old bridge: hold the connection `seconds`, then the socket drops
    /// **before any job_id is delivered** (networkConnectionLost).
    case holdThenDropConnection(seconds: TimeInterval)
    /// The old bridge: hold the connection `seconds`, then time out before any
    /// job_id is delivered.
    case holdThenTimeout(seconds: TimeInterval)
}

/// Per-test configuration of the stub bridge. Mutated on the test thread before
/// the requests run; counters are read after. Internally locked because the
/// URLProtocol handlers run on URLSession's own queues.
final class StubBridge: @unchecked Sendable {
    private let lock = NSLock()

    private var _post: StubPost
    private var _stream: StubStreamBehavior
    private var _results: [StubResult]
    private var _postCount = 0
    private var _resultCount = 0
    private var _streamCount = 0

    init(post: StubPost,
         stream: StubStreamBehavior = .failImmediately,
         results: [StubResult] = [.done(response: "ok", sessionId: "sess")]) {
        _post = post
        _stream = stream
        _results = results
    }

    var post: StubPost { lock.lock(); defer { lock.unlock() }; return _post }
    var stream: StubStreamBehavior { lock.lock(); defer { lock.unlock() }; return _stream }

    var postCount: Int { lock.lock(); defer { lock.unlock() }; return _postCount }
    var resultCount: Int { lock.lock(); defer { lock.unlock() }; return _resultCount }
    var streamCount: Int { lock.lock(); defer { lock.unlock() }; return _streamCount }

    func recordPost() { lock.lock(); _postCount += 1; lock.unlock() }
    func recordStream() { lock.lock(); _streamCount += 1; lock.unlock() }

    /// Advance through the scripted result replies, repeating the last.
    func nextResult() -> StubResult {
        lock.lock(); defer { lock.unlock() }
        let idx = min(_resultCount, _results.count - 1)
        _resultCount += 1
        return _results.isEmpty ? .running : _results[idx]
    }
}

/// In-process `URLProtocol` that answers the three bridge endpoints from the
/// active `StubBridge`. Routes on method + path. Each request is served on a
/// background queue and honors `stopLoading` (so a stalled stream is torn down
/// when the coordinator cancels the loser of the stream/poll race).
final class StubURLProtocol: URLProtocol {
    /// The active stub. Set on the test thread before any request runs; read on
    /// URLSession's queues. Single-writer-before-reads, so unsynchronized.
    nonisolated(unsafe) static var bridge: StubBridge?

    private let lock = NSLock()
    private var cancelled = false

    private func isCancelled() -> Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    override class func canInit(with request: URLRequest) -> Bool { bridge != nil }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let req = request
        let bridge = StubURLProtocol.bridge
        DispatchQueue.global().async { [weak self] in
            self?.serve(req, bridge)
        }
    }

    override func stopLoading() {
        lock.lock(); cancelled = true; lock.unlock()
    }

    // MARK: routing

    private func serve(_ req: URLRequest, _ bridge: StubBridge?) {
        guard let bridge else { fail(URLError(.unknown)); return }
        let path = req.url?.path ?? ""
        let method = req.httpMethod ?? "GET"
        if method == "POST", path == "/jesse" {
            servePost(bridge)
        } else if method == "GET", path.hasPrefix("/jesse/result/") {
            serveResult(bridge)
        } else if method == "GET", path.hasPrefix("/jesse/stream/") {
            serveStream(req, bridge)
        } else {
            send(status: 404)
        }
    }

    private func servePost(_ bridge: StubBridge) {
        switch bridge.post {
        case .immediate202(let jobId):
            bridge.recordPost()
            sendJSON(status: 202, ["job_id": jobId, "status": "running"])
        case .holdThenDropConnection(let seconds):
            bridge.recordPost()
            guard sleepChecking(seconds) else { return }
            fail(URLError(.networkConnectionLost))
        case .holdThenTimeout(let seconds):
            bridge.recordPost()
            guard sleepChecking(seconds) else { return }
            fail(URLError(.timedOut))
        }
    }

    private func serveResult(_ bridge: StubBridge) {
        switch bridge.nextResult() {
        case .running:
            sendJSON(status: 200, ["status": "running"])
        case .done(let response, let sessionId):
            var obj: [String: Any] = ["status": "done", "response": response]
            if let sessionId { obj["session_id"] = sessionId }
            sendJSON(status: 200, obj)
        case .failed(let error):
            sendJSON(status: 200, ["status": "failed", "error": error])
        case .expired:
            send(status: 404)
        case .cancelled:
            sendJSON(status: 200, ["status": "cancelled"])
        case .transportDrop:
            fail(URLError(.networkConnectionLost))
        case .stalledResult:
            // Open nothing, never finish: the request hangs until the session's
            // bounded per-request deadline fires (or the loser is torn down). Only
            // a bounded, non-waiting session can escape this — the whole point of
            // the fix.
            while !isCancelled() { Thread.sleep(forTimeInterval: 0.02) }
        }
    }

    private func serveStream(_ req: URLRequest, _ bridge: StubBridge) {
        bridge.recordStream()
        switch bridge.stream {
        case .failImmediately:
            fail(URLError(.networkConnectionLost))
        case .notFound:
            send(status: 404)
        case .framesThenStall(let frames):
            openSSE()
            for f in frames {
                guard emitFrame(f) else { return }
                if !sleepChecking(0.02) { return }
            }
            // Stall open: never a terminal frame, never a close. Only a teardown
            // (the coordinator cancels the stream when the poll wins) ends it.
            while !isCancelled() { Thread.sleep(forTimeInterval: 0.02) }
        case .framesThenClose(let frames):
            openSSE()
            // Deliver the whole SSE body as a single chunk, then settle before
            // finishing. `URLSession.bytes` + URLProtocol races/coalesces
            // back-to-back `didLoad`/finish calls and can truncate the tail, so a
            // one-shot body + a gap is what reliably surfaces every frame.
            var body = Data()
            for f in frames { body.append(frameBytes(f)) }
            if isCancelled() { return }
            client?.urlProtocol(self, didLoad: body)
            if !sleepChecking(0.1) { return }
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    // MARK: SSE helpers

    /// Send the 200 + text/event-stream response head (no body yet); deltas
    /// follow as `didLoad` chunks so `URLSession.bytes` yields them incrementally.
    private func openSSE() {
        guard !isCancelled(), let url = request.url else { return }
        let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                   headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
    }

    /// The `event:`/`data:` wire bytes for one SSE frame.
    private func frameBytes(_ frame: StubFrame) -> Data {
        let (event, data): (String, [String: Any])
        switch frame {
        case .reset(let t): (event, data) = ("reset", ["text": t])
        case .delta(let t): (event, data) = ("delta", ["text": t])
        case .activity(let n): (event, data) = ("activity", ["name": n])
        case .done(let r, let s):
            var o: [String: Any] = ["response": r]
            if let s { o["session_id"] = s }
            (event, data) = ("done", o)
        case .error(let e): (event, data) = ("error", ["error": e])
        case .cancelled: (event, data) = ("cancelled", [:])
        }
        let json = String(data: try! JSONSerialization.data(withJSONObject: data), encoding: .utf8)!
        return Data("event: \(event)\ndata: \(json)\n\n".utf8)
    }

    /// Push one frame's bytes to the client. Returns false if cancelled.
    private func emitFrame(_ frame: StubFrame) -> Bool {
        if isCancelled() { return false }
        client?.urlProtocol(self, didLoad: frameBytes(frame))
        return true
    }

    // MARK: plain-response helpers

    private func sendJSON(status: Int, _ obj: [String: Any]) {
        let body = try! JSONSerialization.data(withJSONObject: obj)
        send(status: status, headers: ["Content-Type": "application/json"], body: body)
    }

    private func send(status: Int, headers: [String: String] = [:], body: Data? = nil) {
        guard !isCancelled(), let url = request.url else { return }
        let resp = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                   headerFields: headers)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        if let body { client?.urlProtocol(self, didLoad: body) }
        client?.urlProtocolDidFinishLoading(self)
    }

    private func fail(_ error: Error) {
        guard !isCancelled() else { return }
        client?.urlProtocol(self, didFailWithError: error)
    }

    /// Sleep `seconds` in small steps, bailing early if cancelled. Returns false
    /// if cancelled during the sleep.
    private func sleepChecking(_ seconds: TimeInterval) -> Bool {
        let steps = max(1, Int(seconds / 0.02))
        for _ in 0..<steps {
            if isCancelled() { return false }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return !isCancelled()
    }
}

// MARK: - Tests

final class JesseIntegrationTests: XCTestCase {

    private let cfg = JesseConfig(host: "laptop", port: 8765, token: "tok")

    override func tearDown() {
        StubURLProtocol.bridge = nil
        super.tearDown()
    }

    /// A URLSession whose only protocol is the stub — every request is answered
    /// in-process by the active `StubBridge`.
    private func stubSession() -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: c)
    }

    /// The REAL `JesseClient` wired to the stub session.
    private func realClient() -> JesseClient {
        JesseClient(config: cfg, session: stubSession())
    }

    @MainActor
    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: JesseThread.self, Turn.self, OutboxItem.self, OutboxAttachment.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return ModelContext(container)
    }

    /// A coordinator driving the REAL client (built once, ignoring the cfg the
    /// coordinator passes) so the whole send→persist→consume path runs over the
    /// stubbed URLSession.
    @MainActor
    private func makeCoordinator(_ client: JesseClient) -> RunCoordinator {
        RunCoordinator(config: { self.cfg }, makeClient: { _ in client })
    }

    /// Poll `condition` on the main actor until true or the bounded timeout fires
    /// (so a regression *fails* rather than hangs CI).
    @MainActor
    private func waitUntil(_ what: String, timeout: TimeInterval = 8,
                           _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { XCTFail("timed out waiting for: \(what)"); return }
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    @MainActor
    private func jesseTurns(_ thread: JesseThread) -> [Turn] {
        thread.turns.filter { !$0.isUser }
    }

    // MARK: the reproducing test (the orphan bug)

    /// The orphan-bug regression guard.
    ///
    /// Under the OLD grace-holding bridge, `POST /jesse` delivered the job_id
    /// LATE (after up to `JESSE_GRACE_SECS`). A connection drop during that hold
    /// landed **before any job_id reached the phone**, so `RunCoordinator.send`'s
    /// `send()` threw `.connectionLost` with nothing persisted — `handle(error:)`
    /// fell through to a terminal `fail`, orphaning the turn the bridge was still
    /// running. (That exact scenario is what failed on pre-fix code; see the
    /// commit that introduced this file.)
    ///
    /// The FIXED bridge returns `202 {job_id}` immediately, so `inFlight` is
    /// persisted the instant the turn starts — *before* any socket the turn opens
    /// can drop. This test models the fixed contract together with a connection
    /// that is flaky right at the start: the live stream never opens, and the very
    /// first result poll drops. That drop — which under the old bridge would have
    /// preceded the job_id and orphaned the turn — is now fully recoverable: the
    /// retained job_id keeps Re-check available, and a re-check delivers the reply.
    @MainActor
    func testPostDroppedBeforeJobId_turnIsRecoverable() async throws {
        let context = try makeContext()
        // Fixed-bridge contract: immediate 202. Then a flaky start — the stream
        // won't open, and the first poll drops — before a later poll succeeds.
        let bridge = StubBridge(
            post: .immediate202(jobId: "job-flaky-start"),
            stream: .failImmediately,
            results: [.transportDrop, .done(response: "the held reply", sessionId: "sess-held")])
        StubURLProtocol.bridge = bridge
        let coordinator = makeCoordinator(realClient())

        let thread = JesseThread(mode: .ask)
        coordinator.send(thread: thread, text: "a long question", voice: false, context: context)

        // The start-of-turn drop is recoverable, NOT a terminal orphan: the run
        // settles with the job_id retained and Re-check available.
        await waitUntil("the turn to settle into a recoverable state") {
            coordinator.canRecheck(thread.id) || !self.jesseTurns(thread).isEmpty
        }
        XCTAssertTrue(coordinator.canRecheck(thread.id),
                      "a drop right at turn start must retain the job_id for Re-check, not orphan it")
        XCTAssertTrue(jesseTurns(thread).isEmpty, "no reply yet — it's pending a re-check")

        // And the reply is ultimately delivered: Re-check re-attaches and the next
        // poll returns done.
        coordinator.recheck(thread.id, context: context)
        await waitUntil("the reply to be delivered via re-check") {
            !self.jesseTurns(thread).isEmpty
        }
        XCTAssertEqual(jesseTurns(thread).count, 1, "exactly one reply after recovery")
        XCTAssertEqual(jesseTurns(thread).first?.text, "the held reply")
        XCTAssertEqual(thread.sessionId, "sess-held")
        XCTAssertFalse(coordinator.isRunning(thread.id))
        XCTAssertFalse(coordinator.canRecheck(thread.id), "job cleared once delivered")
        XCTAssertNil(coordinator.error(for: thread.id))
    }

    // MARK: the rest of the matrix (all against the real client via the stub)

    /// Normal long turn: 202 immediately, the live stream never completes (poll
    /// owns it), poll resolves to done → exactly one persisted Turn.
    @MainActor
    func testImmediate202ThenPollDone() async throws {
        let context = try makeContext()
        let bridge = StubBridge(
            post: .immediate202(jobId: "job-long"),
            stream: .failImmediately,
            results: [.running, .done(response: "the long answer", sessionId: "sess-long")])
        StubURLProtocol.bridge = bridge
        let coordinator = makeCoordinator(realClient())

        let thread = JesseThread(mode: .ask)
        coordinator.send(thread: thread, text: "a long question", voice: false, context: context)

        await waitUntil("the long turn to finish via poll") { !self.jesseTurns(thread).isEmpty }
        XCTAssertEqual(jesseTurns(thread).count, 1, "exactly one Turn for one completed turn")
        XCTAssertEqual(jesseTurns(thread).first?.text, "the long answer")
        XCTAssertEqual(thread.sessionId, "sess-long")
        XCTAssertFalse(coordinator.isRunning(thread.id))
        XCTAssertNil(coordinator.error(for: thread.id))
    }

    /// The half-open hang guard: the stream opens, renders a reset, then stalls
    /// forever (never a terminal frame, never a close). The concurrent poll must
    /// still complete the turn — driven by a BOUNDED test timeout so a regression
    /// (the old "stream then fall back" logic) FAILS here rather than hanging CI.
    @MainActor
    func testHalfOpenStreamStillCompletesViaPoll() async throws {
        let context = try makeContext()
        // A `reset` carries the text-so-far; a trailing `activity` frame flushes
        // it (a frame is dispatched when the next event line arrives) and then the
        // stream stalls — no terminal frame, no close.
        let bridge = StubBridge(
            post: .immediate202(jobId: "job-halfopen"),
            stream: .framesThenStall([.reset("Hello world"), .activity("Read")]),
            results: [.running, .done(response: "Hello world", sessionId: "sess-ho")])
        StubURLProtocol.bridge = bridge
        let coordinator = makeCoordinator(realClient())

        let thread = JesseThread(mode: .ask)
        coordinator.send(thread: thread, text: "greet me", voice: false, context: context)

        // The stalled stream still renders its partial text live (proves the SSE
        // bytes were parsed) — observable while the poll is still running.
        await waitUntil("the stalled stream to render its partial text", timeout: 4) {
            coordinator.partialText(for: thread.id) == "Hello world"
        }

        // …and the poll completes the turn despite the stream never closing.
        await waitUntil("the poll to complete the half-open turn", timeout: 6) {
            !self.jesseTurns(thread).isEmpty
        }
        XCTAssertEqual(jesseTurns(thread).count, 1, "one Turn, no hang, no duplicate")
        XCTAssertEqual(jesseTurns(thread).first?.text, "Hello world")
        XCTAssertFalse(coordinator.isRunning(thread.id))
        XCTAssertNil(coordinator.partialText(for: thread.id), "partial buffer cleared on finish")
    }

    /// Real SSE bytes — reset, deltas, then a terminal `done` — parsed by the real
    /// `JesseClient.stream` byte-level parser (the path the fake never touched).
    /// The poll only ever returns `running`, so the stream's parsed `done` is the
    /// only thing that can finish the turn: a end-to-end guard on the parser.
    @MainActor
    func testStreamDeltasThenDoneRendersAndFinishes() async throws {
        let context = try makeContext()
        let bridge = StubBridge(
            post: .immediate202(jobId: "job-stream"),
            stream: .framesThenClose([
                .reset(""), .delta("Hello "), .activity("Read"), .delta("world"),
                .done(response: "Hello world", sessionId: "sess-stream"),
            ]),
            results: [.running])   // poll never completes — the stream must
        StubURLProtocol.bridge = bridge
        let coordinator = makeCoordinator(realClient())

        let thread = JesseThread(mode: .ask)
        coordinator.send(thread: thread, text: "greet me", voice: false, context: context)

        await waitUntil("the streamed done to finish the turn") { !self.jesseTurns(thread).isEmpty }
        XCTAssertEqual(jesseTurns(thread).count, 1, "exactly one Turn from the streamed done")
        XCTAssertEqual(jesseTurns(thread).first?.text, "Hello world",
                       "the real byte-level parser assembled reset+deltas+done")
        XCTAssertEqual(thread.sessionId, "sess-stream")
        XCTAssertFalse(coordinator.isRunning(thread.id))
        XCTAssertNil(coordinator.error(for: thread.id))
    }

    /// A 404 from `GET /jesse/result` (the bridge no longer has the job — past its
    /// TTL) is the one genuinely terminal "gone" state: surface it, drop the job,
    /// nothing left to re-check.
    @MainActor
    func testResultExpired404IsTerminal() async throws {
        let context = try makeContext()
        let bridge = StubBridge(
            post: .immediate202(jobId: "job-expired"),
            stream: .failImmediately,
            results: [.expired])
        StubURLProtocol.bridge = bridge
        let coordinator = makeCoordinator(realClient())

        let thread = JesseThread(mode: .ask)
        coordinator.send(thread: thread, text: "what was it", voice: false, context: context)

        await waitUntil("the expired turn to settle terminally") {
            coordinator.error(for: thread.id) != nil
        }
        XCTAssertNotNil(coordinator.error(for: thread.id))
        XCTAssertFalse(coordinator.canRecheck(thread.id), "expired drops the job — nothing to re-check")
        XCTAssertFalse(coordinator.isRunning(thread.id))
        XCTAssertTrue(jesseTurns(thread).isEmpty)
    }

    /// A bridge-reported `failed` is RECOVERABLE: surface the message but keep the
    /// job_id retained so Re-check / resume can try again.
    @MainActor
    func testResultFailedIsRecoverable() async throws {
        let context = try makeContext()
        let bridge = StubBridge(
            post: .immediate202(jobId: "job-failed"),
            stream: .failImmediately,
            results: [.failed("Jesse hit a snag")])
        StubURLProtocol.bridge = bridge
        let coordinator = makeCoordinator(realClient())

        let thread = JesseThread(mode: .ask)
        coordinator.send(thread: thread, text: "do the thing", voice: false, context: context)

        await waitUntil("the failed turn to settle recoverably") {
            coordinator.error(for: thread.id) != nil
        }
        XCTAssertEqual(coordinator.error(for: thread.id), "Jesse hit a snag")
        XCTAssertTrue(coordinator.canRecheck(thread.id), "a failure stays re-checkable (job retained)")
        XCTAssertFalse(coordinator.isRunning(thread.id))
        XCTAssertTrue(jesseTurns(thread).isEmpty)
    }

    /// (C1) A poll that observes `{"status":"cancelled"}` on a resumed/rechecked
    /// job must return the thread to idle — NOT a permanently stuck Re-check.
    ///
    /// Pre-fix, `decodeResult` threw `.decoding` on the `cancelled` status (it only
    /// handled running/done/failed); the poll mapped that to a recoverable failure,
    /// so Re-check re-polled into the same error forever. This drives the exact
    /// path: an initial transport drop retains the job (Re-check available), then a
    /// re-check whose poll returns `cancelled` clears the run cleanly.
    @MainActor
    func testCancelledStatusOnResumedJobEndsIdleNotStuckRecheck() async throws {
        let context = try makeContext()
        // First poll drops (→ recoverable, job retained); the re-check's poll then
        // reports the turn was cancelled server-side.
        let bridge = StubBridge(
            post: .immediate202(jobId: "job-cancelled"),
            stream: .failImmediately,
            results: [.transportDrop, .cancelled])
        StubURLProtocol.bridge = bridge
        let coordinator = makeCoordinator(realClient())

        let thread = JesseThread(mode: .ask)
        coordinator.send(thread: thread, text: "a question", voice: false, context: context)

        // The drop leaves the turn recoverable with the job retained.
        await waitUntil("the turn to settle recoverably after the drop") {
            coordinator.canRecheck(thread.id)
        }
        XCTAssertTrue(coordinator.canRecheck(thread.id))

        // Re-check: the poll now sees `cancelled` — the run must clear to idle.
        coordinator.recheck(thread.id, context: context)
        await waitUntil("the cancelled poll to clear the run to idle") {
            !coordinator.isRunning(thread.id) && coordinator.inFlight[thread.id] == nil
        }
        XCTAssertFalse(coordinator.isRunning(thread.id))
        XCTAssertNil(coordinator.inFlight[thread.id], "a cancelled job is dropped, not retained")
        XCTAssertFalse(coordinator.canRecheck(thread.id), "no stuck Re-check after cancellation")
        XCTAssertNil(coordinator.error(for: thread.id), "cancellation is not surfaced as an error")
        XCTAssertTrue(jesseTurns(thread).isEmpty, "no reply turn for a cancelled turn")
    }

    // MARK: Bug 2 — bounded session for the short request/response calls

    /// The root-cause guard for the 24h poll hang. The short request/response calls
    /// (`result`, `send`, `cancelJob`, `registerDevice`, `notifyOnComplete`) must go
    /// through a session with a BOUNDED per-request deadline and NO silent
    /// connectivity-wait, so a bridge that goes unreachable mid-turn makes the poll
    /// GET *throw* (→ `pollForOutcome` returns `.failed` → recoverable Re-check)
    /// instead of parking inside `result()` for up to 24h while
    /// `waitsForConnectivity` waits silently. Fails first against the old single
    /// `sharedSession` (`waitsForConnectivity == true`, `timeoutIntervalForRequest
    /// == 86_400`); passes once `session` is the bounded session.
    func testShortCallsUseBoundedNonWaitingSession() {
        let c = JesseClient(config: cfg).session.configuration
        XCTAssertFalse(c.waitsForConnectivity,
                       "short calls must not wait silently for connectivity — a dead bridge has to throw, not hang")
        XCTAssertLessThanOrEqual(c.timeoutIntervalForRequest, 60,
                                 "short calls need a bounded per-request deadline so the poll loop can do its job")
    }

    /// The SSE stream legitimately stays open for the whole turn, so it keeps its
    /// own long-lived session — *separate* from the bounded one above. That
    /// separation is the point: the stream's long timeout can never make the
    /// completion poll (on the bounded session) wait.
    func testStreamUsesLongLivedSession() {
        let c = JesseClient(config: cfg).streamSession.configuration
        XCTAssertGreaterThanOrEqual(c.timeoutIntervalForResource, 3600,
                                    "the SSE stream needs a long resource ceiling — agent runs can exceed any fixed cap")
    }

    /// The behavioral twin of `testHalfOpenStreamStillCompletesViaPoll`: there the
    /// STREAM stalls and the poll answers. Here the POLL itself stalls — `GET
    /// /jesse/result` opens nothing and never finishes (the bridge went unreachable
    /// mid-turn) — and the stream can't help (it fails immediately). With the
    /// bounded, non-waiting session the stalled poll request times out and throws,
    /// so `pollForOutcome` returns `.failed` and the turn settles into a recoverable
    /// Re-check state instead of hanging. Driven on a short (1.5s) bounded session
    /// so the test is fast — the bound mirrors production's bounded session at speed.
    /// Against the old 24h/`waitsForConnectivity` session the poll never returns and
    /// the turn stays running past the wait (verified by temporarily swapping this
    /// session's config to `timeoutIntervalForRequest = 86_400`,
    /// `waitsForConnectivity = true`: the `waitUntil` then times out → XCTFail).
    @MainActor
    func testStalledResultPollSettlesRecoverablyNotHung() async throws {
        let context = try makeContext()
        let bridge = StubBridge(
            post: .immediate202(jobId: "job-stalled-poll"),
            stream: .failImmediately,
            results: [.stalledResult])
        StubURLProtocol.bridge = bridge

        // A bounded, non-waiting session — production's posture, at 1.5s for speed.
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [StubURLProtocol.self]
        c.timeoutIntervalForRequest = 1.5
        c.waitsForConnectivity = false
        let client = JesseClient(config: cfg, session: URLSession(configuration: c))
        let coordinator = makeCoordinator(client)

        let thread = JesseThread(mode: .ask)
        coordinator.send(thread: thread, text: "what happened", voice: false, context: context)

        await waitUntil("the stalled poll to settle into a recoverable state", timeout: 6) {
            coordinator.canRecheck(thread.id)
        }
        XCTAssertTrue(coordinator.canRecheck(thread.id),
                      "a stalled poll on a bounded session times out → recoverable Re-check, not a hang")
        XCTAssertFalse(coordinator.isRunning(thread.id), "the run must not stay marked running")
        XCTAssertNotNil(coordinator.inFlight[thread.id], "the job_id is retained for Re-check")
        XCTAssertNotNil(coordinator.error(for: thread.id))
        XCTAssertTrue(jesseTurns(thread).isEmpty, "no reply — it's pending a re-check")
    }
}
