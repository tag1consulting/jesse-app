import XCTest
import SwiftData
@testable import Jesse

@MainActor
final class ThreadHistoryTests: XCTestCase {

    // MARK: - Wire contract: POST /jesse body decoding

    private func httpResponse(_ code: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "http://example/jesse")!,
                        statusCode: code, httpVersion: nil, headerFields: nil)!
    }

    func testDecodeSendInline200CarriesReplyAndJobId() throws {
        let data = #"{"mode":"ask","response":"hello","session_id":"sess-1","job_id":"job-1"}"#
            .data(using: .utf8)!
        let result = try JesseClient.decodeSend(data: data, resp: httpResponse(200))
        guard case .reply(let reply, let jobId) = result else {
            return XCTFail("expected .reply, got \(result)")
        }
        XCTAssertEqual(reply.text, "hello")
        XCTAssertEqual(reply.sessionId, "sess-1")
        XCTAssertEqual(jobId, "job-1")
    }

    func testDecodeSend202IsRunningWithJobId() throws {
        let data = #"{"job_id":"job-42","status":"running"}"#.data(using: .utf8)!
        let result = try JesseClient.decodeSend(data: data, resp: httpResponse(202))
        guard case .running(let jobId) = result else {
            return XCTFail("expected .running, got \(result)")
        }
        XCTAssertEqual(jobId, "job-42")
    }

    func testDecodeSend202WithoutJobIdThrows() {
        let data = #"{"status":"running"}"#.data(using: .utf8)!
        XCTAssertThrowsError(try JesseClient.decodeSend(data: data, resp: httpResponse(202)))
    }

    func testDecodeSendServerErrorThrowsBadResponse() {
        let data = "boom".data(using: .utf8)!
        XCTAssertThrowsError(try JesseClient.decodeSend(data: data, resp: httpResponse(502))) { error in
            guard case JesseError.badResponse(let code, _) = error else {
                return XCTFail("expected badResponse, got \(error)")
            }
            XCTAssertEqual(code, 502)
        }
    }

    // MARK: - Wire contract: GET /jesse/result/{job_id} decoding

    func testDecodeResultRunning() throws {
        let data = #"{"status":"running"}"#.data(using: .utf8)!
        guard case .running = try JesseClient.decodeResult(data: data, resp: httpResponse(200)) else {
            return XCTFail("expected .running")
        }
    }

    func testDecodeResultDone() throws {
        let data = #"{"status":"done","response":"the answer","session_id":"sess-9"}"#
            .data(using: .utf8)!
        guard case .done(let reply) = try JesseClient.decodeResult(data: data, resp: httpResponse(200)) else {
            return XCTFail("expected .done")
        }
        XCTAssertEqual(reply.text, "the answer")
        XCTAssertEqual(reply.sessionId, "sess-9")
    }

    func testDecodeResultFailed() throws {
        let data = #"{"status":"failed","error":"upstream boom"}"#.data(using: .utf8)!
        guard case .failed(let message) = try JesseClient.decodeResult(data: data, resp: httpResponse(200)) else {
            return XCTFail("expected .failed")
        }
        XCTAssertEqual(message, "upstream boom")
    }

    func testDecodeResult404IsExpiredNotThrow() throws {
        // An evicted/unknown job id is the terminal "gone" state — distinct from
        // a bridge-reported .failed (which stays re-checkable). It must decode to
        // .expired rather than throwing.
        let data = "unknown or expired job id".data(using: .utf8)!
        guard case .expired = try JesseClient.decodeResult(data: data, resp: httpResponse(404)) else {
            return XCTFail("expected .expired for 404")
        }
    }

    func testDecodeResultCancelled() throws {
        // (C1) The bridge serializes a cancelled job as `{"status":"cancelled"}`
        // from GET /jesse/result/{id}. It must decode to .cancelled — not throw
        // .decoding (which the poll mapped to a recoverable failure → a stuck
        // "Re-check" thread that re-polled into the same error forever).
        let data = #"{"status":"cancelled"}"#.data(using: .utf8)!
        guard case .cancelled = try JesseClient.decodeResult(data: data, resp: httpResponse(200)) else {
            return XCTFail("expected .cancelled")
        }
    }

    // MARK: - −1005 → .connectionLost mapping

    func testNetworkConnectionLostMapsToConnectionLost() {
        let ns = NSError(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost)
        guard case .connectionLost = JesseError.from(ns, host: "laptop") else {
            return XCTFail("expected .connectionLost")
        }
    }

    func testOtherURLErrorStillMapsAsBefore() {
        let ns = NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotFindHost)
        guard case .cannotFindHost(let h) = JesseError.from(ns, host: "laptop") else {
            return XCTFail("expected .cannotFindHost")
        }
        XCTAssertEqual(h, "laptop")
    }

    // MARK: - Models

    func testDeriveTitleCollapsesAndTruncates() {
        XCTAssertEqual(JesseThread.deriveTitle(from: "  hi there\nsecond line "), "hi there second line")
        let long = String(repeating: "x", count: 200)
        let title = JesseThread.deriveTitle(from: long)
        XCTAssertTrue(title.hasSuffix("…"))
        XCTAssertLessThanOrEqual(title.count, 61)
    }

    func testOrderedTurnsSortByCreatedAt() {
        let thread = JesseThread(mode: .ask)
        let base = Date()
        let t2 = Turn(role: .jesse, text: "second", createdAt: base.addingTimeInterval(2))
        let t1 = Turn(role: .user, text: "first", createdAt: base.addingTimeInterval(1))
        thread.turns = [t2, t1]
        XCTAssertEqual(thread.orderedTurns.map(\.text), ["first", "second"])
        XCTAssertTrue(t1.isUser)
        XCTAssertFalse(t2.isUser)
    }

    // MARK: - InFlight persistence round-trip

    func testInFlightStoreRoundTrip() {
        let a = UUID(), b = UUID()
        let map: [UUID: InFlightJob] = [
            a: InFlightJob(jobId: "job-a", voice: true),
            b: InFlightJob(jobId: "job-b", voice: false),
        ]
        let store = InFlightStore()
        store.save(map)
        let loaded = store.load()
        XCTAssertEqual(loaded[a], InFlightJob(jobId: "job-a", voice: true))
        XCTAssertEqual(loaded[b], InFlightJob(jobId: "job-b", voice: false))
        store.save([:]) // clean up shared defaults
        XCTAssertTrue(store.load().isEmpty)
    }

    // MARK: - Coordinator behavior

    @MainActor
    func testSendAppendsOptimisticTurnAndSurfacesNotConfigured() async throws {
        let container = try ModelContainer(
            for: JesseThread.self, Turn.self, OutboxItem.self, OutboxAttachment.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        // Empty host/token → JesseClient.send throws .notConfigured before any network.
        let coordinator = RunCoordinator(config: { JesseConfig(host: "", port: 8765, token: "") })

        let thread = JesseThread(mode: .ask)
        coordinator.send(thread: thread, text: "what's on Today?", voice: false, context: context)

        // The user turn shows immediately and the thread is marked running while the
        // outbox item is `.sending`.
        XCTAssertEqual(thread.turns.count, 1)
        XCTAssertEqual(thread.turns.first?.isUser, true)
        XCTAssertEqual(thread.title, "what's on Today?")
        XCTAssertTrue(coordinator.isRunning(thread.id))

        // The doomed (pre-ACK) call resolves quickly. This failure class is owned by
        // the per-message outbox UI, NOT the thread-level banner: the OutboxItem flips
        // to `.failed` with a mapped message, the run clears, and `errors[]` stays nil.
        try await waitUntil { self.failedOutboxItems(for: thread.id, context).count == 1 }
        XCTAssertFalse(coordinator.isRunning(thread.id))
        XCTAssertNil(coordinator.error(for: thread.id),
                     "a pre-ACK failure does not set the thread-level banner")
        let failed = try XCTUnwrap(failedOutboxItems(for: thread.id, context).first)
        XCTAssertEqual(failed.turnID, thread.turns.first?.id, "keyed to the optimistic user turn")
        XCTAssertEqual(failed.attempts, 1)
        XCTAssertEqual(failed.lastError, JesseError.notConfigured.errorDescription)
    }

    @MainActor
    private func failedOutboxItems(for threadID: UUID, _ context: ModelContext) -> [OutboxItem] {
        let failed = OutboxState.failed.rawValue
        let d = FetchDescriptor<OutboxItem>(
            predicate: #Predicate { $0.threadID == threadID && $0.stateRaw == failed })
        return (try? context.fetch(d)) ?? []
    }

    @MainActor
    func testSecondSendIgnoredWhileRunning() async throws {
        let container = try ModelContainer(
            for: JesseThread.self, Turn.self, OutboxItem.self, OutboxAttachment.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let coordinator = RunCoordinator(config: { JesseConfig(host: "", port: 8765, token: "") })
        let thread = JesseThread(mode: .ask)

        coordinator.send(thread: thread, text: "first", voice: false, context: context)
        // A second send while the first is in flight is a no-op (one run per thread).
        coordinator.send(thread: thread, text: "second", voice: false, context: context)
        XCTAssertEqual(thread.turns.count, 1)

        try await waitUntil { !coordinator.isRunning(thread.id) }
    }

    // Poll a condition on the main actor with a timeout.
    @MainActor
    private func waitUntil(timeout: TimeInterval = 3,
                           _ condition: () -> Bool) async throws {
        let start = Date()
        while !condition() {
            if Date().timeIntervalSince(start) > timeout {
                return XCTFail("condition not met within \(timeout)s")
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
