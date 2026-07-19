import XCTest
import SwiftData
@testable import Jesse

// Tests for the push surface added to the app: the two new `JesseClient` calls
// (device registration + notify-on-complete) over a URLProtocol stub, the
// `JesseConfig.isConfigured` gate, and the coordinator's background-notify and
// tap-routing helpers. No real network and no real APNs.

// MARK: - Capturing URLProtocol stub

/// Records the request the client built and replies with a scripted status. Body
/// is captured from `httpBodyStream` (URLSession moves `httpBody` there).
// No `@unchecked Sendable`: `URLProtocol`'s `Sendable` conformance is unavailable,
// so declaring one is redundant (and warns). The shared scripting state is
// `nonisolated(unsafe)` static, written on the test thread before a request runs.
final class CapturingProtocol: URLProtocol {
    struct Captured {
        var method: String
        var path: String
        var authorization: String?
        var body: Data?
    }
    nonisolated(unsafe) static var captured: Captured?
    nonisolated(unsafe) static var status: Int = 200

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            let bufSize = 4096
            let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
            defer { buf.deallocate(); stream.close() }
            while stream.hasBytesAvailable {
                let read = stream.read(buf, maxLength: bufSize)
                if read <= 0 { break }
                data.append(buf, count: read)
            }
            body = data
        }
        Self.captured = Captured(
            method: request.httpMethod ?? "",
            path: request.url?.path ?? "",
            authorization: request.value(forHTTPHeaderField: "Authorization"),
            body: body)
        let resp = HTTPURLResponse(url: request.url!, statusCode: Self.status,
                                   httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// A `JesseClient` whose session routes through this protocol.
    @MainActor
    static func makeClient(host: String = "laptop", token: String = "tok") -> JesseClient {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [CapturingProtocol.self]
        return JesseClient(config: JesseConfig(host: host, port: 8765, token: token),
                           session: URLSession(configuration: cfg))
    }
}

@MainActor
final class PushTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        CapturingProtocol.captured = nil
        CapturingProtocol.status = 200
        // Clear any in-flight jobs other tests persisted to the shared
        // UserDefaults store, so a coordinator built here starts clean (the
        // background-notify test iterates every in-flight job).
        InFlightStore().save([:])
    }

    // MARK: - isConfigured

    func testIsConfigured() {
        XCTAssertTrue(JesseConfig(host: "laptop", port: 8765, token: "t").isConfigured)
        XCTAssertFalse(JesseConfig(host: "", port: 8765, token: "t").isConfigured)
        XCTAssertFalse(JesseConfig(host: "laptop", port: 8765, token: "").isConfigured)
    }

    // MARK: - registerDevice

    func testRegisterDevicePostsTokenWithAuth() async throws {
        CapturingProtocol.status = 200
        let client = CapturingProtocol.makeClient(token: "secret")
        try await client.registerDevice(token: "abc123devicetoken")

        let cap = try XCTUnwrap(CapturingProtocol.captured)
        XCTAssertEqual(cap.method, "POST")
        XCTAssertEqual(cap.path, "/jesse/device")
        XCTAssertEqual(cap.authorization, "Bearer secret")
        let body = try XCTUnwrap(cap.body)
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(obj["token"] as? String, "abc123devicetoken")
    }

    func testRegisterDeviceThrowsOnUnauthorized() async {
        CapturingProtocol.status = 401
        let client = CapturingProtocol.makeClient()
        do {
            try await client.registerDevice(token: "x")
            XCTFail("401 must throw")
        } catch {
            // expected
        }
    }

    func testRegisterDeviceNotConfiguredThrows() async {
        let client = JesseClient(config: JesseConfig(host: "", port: 8765, token: ""))
        do {
            try await client.registerDevice(token: "x")
            XCTFail("an unconfigured client must throw notConfigured")
        } catch {
            // expected
        }
    }

    // MARK: - notifyOnComplete

    func testNotifyPostsToJobPath() async throws {
        CapturingProtocol.status = 204
        let client = CapturingProtocol.makeClient(token: "tok")
        try await client.notifyOnComplete(jobId: "job-xyz")

        let cap = try XCTUnwrap(CapturingProtocol.captured)
        XCTAssertEqual(cap.method, "POST")
        XCTAssertEqual(cap.path, "/jesse/notify/job-xyz")
        XCTAssertEqual(cap.authorization, "Bearer tok")
    }

    func testNotifyTreats404AsSuccess() async throws {
        // The bridge no longer knows the id — nothing to ping, not an error.
        CapturingProtocol.status = 404
        let client = CapturingProtocol.makeClient()
        try await client.notifyOnComplete(jobId: "gone")
    }

    func testNotifyThrowsOnServerError() async {
        CapturingProtocol.status = 500
        let client = CapturingProtocol.makeClient()
        do {
            try await client.notifyOnComplete(jobId: "j")
            XCTFail("500 must throw")
        } catch {
            // expected
        }
    }

    // MARK: - coordinator background-notify + tap routing + first-success hook

    /// Fake client: keeps a turn in flight by polling `.running` forever (no
    /// parked continuation to leak), and records every `notifyOnComplete` call.
    @MainActor
    private final class NotifyFakeClient: JesseClientProtocol {
        var notifiedJobIds: [String] = []
        var onNotify: (() -> Void)?

        func send(mode: JesseMode, text: String, sessionId: String?, voice: Bool,
                  instructions: String?, floorOverride: String?,
                  attachments: [JesseAttachment]) async throws -> JesseSendResult {
            .running(jobId: "job-bg")
        }
        func result(jobId: String) async throws -> JesseResultState {
            .running // poll loop sleeps 2s and re-polls; the turn stays in flight
        }
        func cancelJob(jobId: String) async throws {}
        func stream(jobId: String) -> AsyncThrowingStream<JesseStreamEvent, Error> {
            AsyncThrowingStream { $0.finish() }
        }
        func notifyOnComplete(jobId: String) async throws {
            notifiedJobIds.append(jobId)
            onNotify?()
        }
    }

    @MainActor
    func testBackgroundNotifyFlagsInFlightJobAndRoutingFindsThread() async throws {
        let container = try ModelContainer(
            for: JesseThread.self, Turn.self, OutboxItem.self, OutboxAttachment.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)

        let fake = NotifyFakeClient()
        let coordinator = RunCoordinator(
            config: { JesseConfig(host: "laptop", port: 8765, token: "tok") },
            makeClient: { _ in fake })

        let thread = JesseThread(mode: .ask)
        coordinator.send(thread: thread, text: "long one", voice: false, context: context)

        // Wait for the 202 to land and the job to be persisted in flight.
        for _ in 0..<50 where coordinator.inFlight[thread.id] == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNotNil(coordinator.inFlight[thread.id])

        // Routing: the in-flight job id resolves back to its thread.
        XCTAssertEqual(coordinator.threadID(forJobId: "job-bg"), thread.id)

        // Backgrounding fires the notify for the in-flight job.
        let notified = expectation(description: "notifyOnComplete called")
        notified.assertForOverFulfill = false
        fake.onNotify = { notified.fulfill() }
        coordinator.notifyBackgroundInFlight()
        await fulfillment(of: [notified], timeout: 2)
        XCTAssertEqual(fake.notifiedJobIds, ["job-bg"])

        coordinator.cancel(thread.id) // tidy up the running poll task
        // Let the cancelled poll task observe cancellation and fully tear down
        // (release its background-task grant) before this test returns, so no
        // stray task lingers into a later test.
        try await Task.sleep(for: .milliseconds(100))
    }

    @MainActor
    func testFirstSuccessHookFiresOnDeliveredReply() async throws {
        let container = try ModelContainer(
            for: JesseThread.self, Turn.self, OutboxItem.self, OutboxAttachment.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)

        // A client that immediately completes the turn via the stream `done` frame.
        final class DoneClient: JesseClientProtocol, @unchecked Sendable {
            func send(mode: JesseMode, text: String, sessionId: String?, voice: Bool,
                      instructions: String?, floorOverride: String?,
                      attachments: [JesseAttachment]) async throws -> JesseSendResult {
                .running(jobId: "job-done")
            }
            func result(jobId: String) async throws -> JesseResultState {
                .done(JesseReply(text: "the answer", sessionId: "sess"))
            }
            func cancelJob(jobId: String) async throws {}
            func stream(jobId: String) -> AsyncThrowingStream<JesseStreamEvent, Error> {
                AsyncThrowingStream { $0.finish() }
            }
        }

        var hookFired = false
        let coordinator = RunCoordinator(
            config: { JesseConfig(host: "laptop", port: 8765, token: "tok") },
            makeClient: { _ in DoneClient() },
            onFirstSuccess: { hookFired = true })

        let thread = JesseThread(mode: .ask)
        coordinator.send(thread: thread, text: "q", voice: false, context: context)

        // Wait for the reply to land.
        for _ in 0..<50 where !hookFired { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(hookFired, "the first-success hook must fire when a reply is delivered")
        XCTAssertEqual(thread.turns.filter { !$0.isUser }.count, 1)
    }
}
