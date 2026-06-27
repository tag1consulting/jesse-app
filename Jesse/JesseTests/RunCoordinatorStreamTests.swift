import XCTest
import SwiftData
@testable import Jesse

/// The live-streaming path of the coordinator, driven through the
/// `JesseClientProtocol` seam with no server. A turn that outran the grace window
/// (`.running`) opens the SSE stream; these tests assert the partial buffer
/// updates incrementally, that exactly one persisted `Turn` is created on `done`,
/// that a dropped stream falls back to polling, and that a `cancelled` frame is
/// treated as the user's own cancel (no Turn, no error).
final class RunCoordinatorStreamTests: XCTestCase {

    /// A client whose `stream` is driven by hand: the test yields events and then
    /// awaits a beat so the coordinator's main-actor consume loop processes them.
    /// `result` backs the poll fallback for the dropped-stream test.
    @MainActor
    private final class StreamingFakeClient: JesseClientProtocol {
        var onStreamStarted: (() -> Void)?
        var resultProvider: (() async throws -> JesseResultState)?
        private var continuation: AsyncThrowingStream<JesseStreamEvent, Error>.Continuation?

        func send(mode: JesseMode, text: String, sessionId: String?, voice: Bool,
                  instructions: String?, floorOverride: String?,
                  attachments: [JesseAttachment]) async throws -> JesseSendResult {
            // Always outrun the grace window so the coordinator streams.
            .running(jobId: "job-stream")
        }

        func result(jobId: String) async throws -> JesseResultState {
            if let resultProvider { return try await resultProvider() }
            return .running
        }

        func cancelJob(jobId: String) async throws {}

        func stream(jobId: String) -> AsyncThrowingStream<JesseStreamEvent, Error> {
            AsyncThrowingStream { cont in
                self.continuation = cont
                self.onStreamStarted?()
            }
        }

        func emit(_ event: JesseStreamEvent) { continuation?.yield(event) }
        func finishStream() { continuation?.finish() }
        func failStream(_ error: Error) { continuation?.finish(throwing: error) }
    }

    @MainActor
    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: JesseThread.self, Turn.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return ModelContext(container)
    }

    @MainActor
    private func makeCoordinator(_ fake: StreamingFakeClient) -> RunCoordinator {
        RunCoordinator(
            config: { JesseConfig(host: "laptop", port: 8765, token: "tok") },
            makeClient: { _ in fake })
    }

    /// Let the coordinator's consume loop process whatever was just yielded.
    private func settle() async throws { try await Task.sleep(for: .milliseconds(30)) }

    @MainActor
    func testDeltasBuildPartialThenSingleTurnOnDone() async throws {
        let context = try makeContext()
        let fake = StreamingFakeClient()
        let opened = expectation(description: "stream opened")
        fake.onStreamStarted = { opened.fulfill() }
        let coordinator = makeCoordinator(fake)

        let thread = JesseThread(mode: .ask)
        coordinator.send(thread: thread, text: "greet me", voice: false, context: context)
        await fulfillment(of: [opened], timeout: 2)

        // Only the optimistic user turn so far.
        XCTAssertEqual(thread.turns.count, 1)
        XCTAssertTrue(coordinator.isRunning(thread.id))

        fake.emit(.delta("Hello "))
        try await settle()
        XCTAssertEqual(coordinator.partialText(for: thread.id), "Hello ")

        fake.emit(.activity("Read"))
        try await settle()
        XCTAssertEqual(coordinator.activity(for: thread.id), "Reading the vault…")

        fake.emit(.delta("world"))
        try await settle()
        XCTAssertEqual(coordinator.partialText(for: thread.id), "Hello world")

        // The authoritative done frame finalizes the turn.
        fake.emit(.done(JesseReply(text: "Hello world", sessionId: "sess-1")))
        try await settle()

        let jesseTurns = thread.turns.filter { !$0.isUser }
        XCTAssertEqual(jesseTurns.count, 1, "exactly one persisted Jesse turn on done")
        XCTAssertEqual(jesseTurns.first?.text, "Hello world")
        XCTAssertEqual(thread.sessionId, "sess-1")
        XCTAssertNil(coordinator.partialText(for: thread.id), "partial buffer cleared on done")
        XCTAssertNil(coordinator.activity(for: thread.id))
        XCTAssertFalse(coordinator.isRunning(thread.id))
        XCTAssertNil(coordinator.error(for: thread.id))
    }

    @MainActor
    func testStreamDropFallsBackToPoll() async throws {
        let context = try makeContext()
        let fake = StreamingFakeClient()
        // The poll fallback returns the finished reply the dropped stream missed.
        fake.resultProvider = { .done(JesseReply(text: "from poll", sessionId: "sess-p")) }
        let opened = expectation(description: "stream opened")
        fake.onStreamStarted = { opened.fulfill() }
        let coordinator = makeCoordinator(fake)

        let thread = JesseThread(mode: .ask)
        coordinator.send(thread: thread, text: "long one", voice: false, context: context)
        await fulfillment(of: [opened], timeout: 2)

        // The connection drops mid-turn (no terminal frame) → fall back to poll.
        fake.failStream(JesseError.connectionLost)
        // Poll runs on the 2s cadence only after the first immediate fetch; the
        // first result() resolves to done, so a short wait is enough.
        try await Task.sleep(for: .milliseconds(100))

        let jesseTurns = thread.turns.filter { !$0.isUser }
        XCTAssertEqual(jesseTurns.count, 1, "poll fallback completed the turn")
        XCTAssertEqual(jesseTurns.first?.text, "from poll")
        XCTAssertFalse(coordinator.isRunning(thread.id))
        XCTAssertNil(coordinator.error(for: thread.id))
    }

    @MainActor
    func testCancelledFrameMidStreamLeavesNoTurnNoError() async throws {
        let context = try makeContext()
        let fake = StreamingFakeClient()
        let opened = expectation(description: "stream opened")
        fake.onStreamStarted = { opened.fulfill() }
        let coordinator = makeCoordinator(fake)

        let thread = JesseThread(mode: .ask)
        coordinator.send(thread: thread, text: "cancel me", voice: false, context: context)
        await fulfillment(of: [opened], timeout: 2)

        fake.emit(.delta("half an answer"))
        try await settle()
        XCTAssertEqual(coordinator.partialText(for: thread.id), "half an answer")

        // A server-driven cancelled frame must read as the user's own cancel.
        fake.emit(.cancelled)
        try await settle()

        XCTAssertEqual(thread.turns.filter { !$0.isUser }.count, 0,
                       "no Jesse turn for a cancelled stream")
        XCTAssertNil(coordinator.partialText(for: thread.id), "partial buffer cleared")
        XCTAssertNil(coordinator.error(for: thread.id), "cancel must not surface an error")
        XCTAssertFalse(coordinator.isRunning(thread.id))
    }
}
