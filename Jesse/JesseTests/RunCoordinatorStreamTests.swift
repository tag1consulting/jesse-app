import XCTest
import SwiftData
@testable import Jesse

/// The live-streaming path of the coordinator, driven through the
/// `JesseClientProtocol` seam with no server. A turn that outran the grace window
/// (`.running`) opens the SSE stream; these tests assert the partial buffer
/// updates incrementally, that exactly one persisted `Turn` is created on `done`,
/// that a dropped stream falls back to polling, and that a `cancelled` frame is
/// treated as the user's own cancel (no Turn, no error).
@MainActor
final class RunCoordinatorStreamTests: XCTestCase {

    /// A client whose `stream` is driven by hand: the test yields events and then
    /// awaits a beat so the coordinator's main-actor consume loop processes them.
    /// `result` backs the poll fallback for the dropped-stream test.
    @MainActor
    private final class StreamingFakeClient: JesseClientProtocol {
        var onStreamStarted: (() -> Void)?
        var resultProvider: (() async throws -> JesseResultState)?
        /// Scripted poll results consumed in order (the last repeats), used when
        /// `resultProvider` is nil. Lets a test drive a `running → done` cadence
        /// with no mutable-capture closure. Each call counts via `pollCalls`.
        var pollResults: [JesseResultState] = []
        private(set) var pollCalls = 0
        private var continuation: AsyncThrowingStream<JesseStreamEvent, Error>.Continuation?

        func send(mode: JesseMode, text: String, sessionId: String?, voice: Bool,
                  instructions: String?, floorOverride: String?,
                  attachments: [JesseAttachment]) async throws -> JesseSendResult {
            // Always outrun the grace window so the coordinator streams.
            .running(jobId: "job-stream")
        }

        func result(jobId: String) async throws -> JesseResultState {
            pollCalls += 1
            if let resultProvider { return try await resultProvider() }
            if !pollResults.isEmpty {
                return pollResults[min(pollCalls - 1, pollResults.count - 1)]
            }
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
            for: JesseThread.self, Turn.self, OutboxItem.self, OutboxAttachment.self,
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

        // The observable `partialText` is coalesced to ~10Hz: this second delta
        // lands inside the first publish's cooldown, so it's surfaced by the
        // deferred flush at the interval boundary rather than immediately. Poll past
        // that boundary (the exact concatenation is preserved — nothing is dropped).
        fake.emit(.delta("world"))
        let deadline = Date().addingTimeInterval(3)
        while coordinator.partialText(for: thread.id) != "Hello world",
              Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
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

    /// THE BUG (regression guard): a half-open stream — the SSE connection opens
    /// and then never yields a frame and never finishes (phone suspended, NAT/idle
    /// timeout, a wedged proxy). Before the fix, `consume` blocked forever in the
    /// stream loop and never polled, so the turn hung. Now stream and poll run
    /// concurrently, so the poll still completes the turn. The poll reports
    /// `running` then `done`, so this also proves the poll loop iterates past a
    /// `.running` on its 2s cadence. Must fail (hang → no Jesse turn) before the
    /// fix and pass after.
    @MainActor
    func testStalledStreamStillFinishesViaPoll() async throws {
        let context = try makeContext()
        let fake = StreamingFakeClient()
        // The stream opens but is half-open: never yields, never finishes. (The
        // test deliberately never calls emit/finishStream/failStream.)
        let opened = expectation(description: "stream opened")
        fake.onStreamStarted = { opened.fulfill() }
        // First poll: still running (forces a 2s sleep). Second: the finished reply.
        fake.pollResults = [
            .running,
            .done(JesseReply(text: "from poll despite a stalled stream", sessionId: "sess-stall")),
        ]
        let coordinator = makeCoordinator(fake)

        let thread = JesseThread(mode: .ask)
        coordinator.send(thread: thread, text: "stall me", voice: false, context: context)
        await fulfillment(of: [opened], timeout: 2)

        // The stream contributes nothing. Wait past the poll's 2s cadence so its
        // second fetch (the done) lands and finalizes the turn.
        try await Task.sleep(for: .milliseconds(2500))

        let jesseTurns = thread.turns.filter { !$0.isUser }
        XCTAssertEqual(jesseTurns.count, 1, "poll completes the turn even though the stream stalled")
        XCTAssertEqual(jesseTurns.first?.text, "from poll despite a stalled stream")
        XCTAssertEqual(thread.sessionId, "sess-stall")
        XCTAssertGreaterThanOrEqual(fake.pollCalls, 2, "the poll loop iterated past a .running")
        XCTAssertFalse(coordinator.isRunning(thread.id))
        XCTAssertNil(coordinator.error(for: thread.id))
        XCTAssertNil(coordinator.partialText(for: thread.id))
    }

    /// Poll wins while the stream is mid-delta (it streamed some text but no
    /// terminal frame): exactly one terminal action, one persisted `Turn`, no
    /// duplicate from the still-open stream, and the partial buffer cleared.
    @MainActor
    func testPollWinsWhileStreamMidDelta() async throws {
        let context = try makeContext()
        let fake = StreamingFakeClient()
        // The poll holds off one beat, then resolves done — long enough for a
        // delta to render first, short enough to win before any terminal frame.
        fake.pollResults = [.running, .done(JesseReply(text: "settled by poll", sessionId: "sess-x"))]
        let opened = expectation(description: "stream opened")
        fake.onStreamStarted = { opened.fulfill() }
        let coordinator = makeCoordinator(fake)

        let thread = JesseThread(mode: .ask)
        coordinator.send(thread: thread, text: "race", voice: false, context: context)
        await fulfillment(of: [opened], timeout: 2)

        // The stream renders a partial but never sends a terminal frame.
        fake.emit(.delta("half a thought"))
        try await settle()
        XCTAssertEqual(coordinator.partialText(for: thread.id), "half a thought")

        // The poll resolves the turn while the stream is still open mid-delta.
        try await Task.sleep(for: .milliseconds(2500))

        let jesseTurns = thread.turns.filter { !$0.isUser }
        XCTAssertEqual(jesseTurns.count, 1, "exactly one terminal action — the poll's")
        XCTAssertEqual(jesseTurns.first?.text, "settled by poll")
        XCTAssertNil(coordinator.partialText(for: thread.id), "partial cleared on finish")
        XCTAssertFalse(coordinator.isRunning(thread.id))
        XCTAssertNil(coordinator.error(for: thread.id))

        // A late terminal frame from the now-cancelled stream must be a no-op.
        fake.emit(.done(JesseReply(text: "stream too late", sessionId: "sess-late")))
        fake.finishStream()
        try await settle()
        XCTAssertEqual(thread.turns.filter { !$0.isUser }.count, 1, "no duplicate Turn from the late stream")
    }

    /// (Bug 3 — defense-in-depth) `consume`'s task group can yield nil with NO user
    /// cancel: the stream ends bare (no terminal frame) AND the poll returns nil
    /// because its own task was cancelled out from under it (not the parent). Before
    /// the fix, `consume`'s `guard let outcome else { return }` then returned
    /// silently — leaving `startDates`/`inFlight` set so `isRunning` stayed true (a
    /// spinner forever, no reply, no error, no Re-check). Now that nil-without-cancel
    /// surfaces a recoverable failure: the run stops (`isRunning == false`) and the
    /// job_id stays retained (`canRecheck == true`) so Re-check can recover it.
    ///
    /// Fails first (pre-fix `consume` returns silently → `isRunning` stays true and
    /// `canRecheck` is false); passes after the recoverable-failure guard.
    @MainActor
    func testGroupYieldsNilWithoutUserCancelSurfacesRecheckNotStuckRunning() async throws {
        let context = try makeContext()
        let fake = StreamingFakeClient()
        let opened = expectation(description: "stream opened")
        fake.onStreamStarted = { opened.fulfill() }
        // The poll returns nil-equivalent: it cancels its OWN task and throws,
        // exactly as a cancelled URL load resolves — so `pollForOutcome`'s
        // `if Task.isCancelled { return nil }` path fires — WITHOUT the parent
        // `consume` task being user-cancelled. (Cancelling a child task does not
        // cancel its parent or siblings.)
        fake.resultProvider = {
            withUnsafeCurrentTask { $0?.cancel() }
            throw CancellationError()
        }
        let coordinator = makeCoordinator(fake)

        let thread = JesseThread(mode: .ask)
        coordinator.send(thread: thread, text: "lose contact", voice: false, context: context)
        await fulfillment(of: [opened], timeout: 2)

        // End the stream bare (no terminal frame) so the stream child also yields
        // nil → the group yields nil with the parent not cancelled.
        fake.finishStream()
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertFalse(coordinator.isRunning(thread.id),
                       "a nil outcome with no user cancel must not leave the run marked running")
        XCTAssertTrue(coordinator.canRecheck(thread.id),
                      "the job_id is retained so Re-check can pick the reply back up")
        XCTAssertEqual(thread.turns.filter { !$0.isUser }.count, 0,
                       "nothing was delivered — no reply turn")
        XCTAssertNotNil(coordinator.error(for: thread.id),
                        "the lost-contact state surfaces a recoverable error")
        XCTAssertNil(coordinator.partialText(for: thread.id), "partial buffer cleared")
    }

    /// The stream errors immediately (never a usable frame). The concurrent poll
    /// still completes the turn — streaming is best-effort display only.
    @MainActor
    func testStreamErrorsImmediatelyPollCompletes() async throws {
        let context = try makeContext()
        let fake = StreamingFakeClient()
        fake.resultProvider = { .done(JesseReply(text: "poll carried it", sessionId: "sess-e")) }
        let opened = expectation(description: "stream opened")
        fake.onStreamStarted = { opened.fulfill() }
        let coordinator = makeCoordinator(fake)

        let thread = JesseThread(mode: .ask)
        coordinator.send(thread: thread, text: "broken stream", voice: false, context: context)
        await fulfillment(of: [opened], timeout: 2)

        // The stream dies the instant it opens, with no terminal frame.
        fake.failStream(JesseError.connectionLost)
        try await Task.sleep(for: .milliseconds(100))

        let jesseTurns = thread.turns.filter { !$0.isUser }
        XCTAssertEqual(jesseTurns.count, 1, "poll completed the turn despite the stream error")
        XCTAssertEqual(jesseTurns.first?.text, "poll carried it")
        XCTAssertFalse(coordinator.isRunning(thread.id))
        XCTAssertNil(coordinator.error(for: thread.id))
    }
}
