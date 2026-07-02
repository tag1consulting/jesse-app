import XCTest
import SwiftData
@testable import Jesse

/// Item 2 — the watch relay entry point. Drives the relay end-to-end as plain
/// TEXT (no watch hardware) through the same `JesseClientProtocol` seam the
/// `RunCoordinator` tests use, asserting: one turn runs per `requestId`
/// (deduplication), the created thread is tagged `.watch`, BOTH turns persist to
/// the real store, the result carries displayText/spokenText from a stubbed reply,
/// and a stubbed failure yields a clean error value rather than a throw.
final class WatchRelayTests: XCTestCase {

    /// A fake client that counts sends and returns a fixed reply (or fails at the
    /// `result` poll). No live stream — it finishes immediately so completion is
    /// driven by the poll, the authoritative path (as in `RunCoordinatorFinishTests`).
    @MainActor
    private final class RelayFakeClient: JesseClientProtocol {
        var sendCount = 0
        let replyText: String
        let sessionId: String?
        let failAtResult: Bool

        init(replyText: String, sessionId: String? = "sess-relay", failAtResult: Bool = false) {
            self.replyText = replyText
            self.sessionId = sessionId
            self.failAtResult = failAtResult
        }

        func send(mode: JesseMode, text: String, sessionId: String?, voice: Bool,
                  instructions: String?, floorOverride: String?,
                  attachments: [JesseAttachment]) async throws -> JesseSendResult {
            sendCount += 1
            return .running(jobId: "job-relay")
        }

        func result(jobId: String) async throws -> JesseResultState {
            if failAtResult { throw JesseError.timedOut("laptop asleep") }
            return .done(JesseReply(text: replyText, sessionId: sessionId))
        }

        func cancelJob(jobId: String) async throws {}

        func stream(jobId: String) -> AsyncThrowingStream<JesseStreamEvent, Error> {
            AsyncThrowingStream { $0.finish() }
        }
    }

    @MainActor
    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: JesseThread.self, Turn.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return ModelContext(container)
    }

    @MainActor
    private func makeRelay(_ fake: RelayFakeClient) -> WatchRelay {
        let coordinator = RunCoordinator(
            config: { JesseConfig(host: "laptop", port: 8765, token: "tok") },
            makeClient: { _ in fake },
            pollSleep: { _ in })   // no real waiting; result resolves on first poll
        return WatchRelay(coordinator: coordinator)
    }

    @MainActor
    private func allThreads(_ context: ModelContext) throws -> [JesseThread] {
        try context.fetch(FetchDescriptor<JesseThread>())
    }

    // MARK: - Happy path: tag, persist both turns, populate the result

    @MainActor
    func testRelayTagsWatchPersistsBothTurnsAndReturnsResult() async throws {
        let fake = RelayFakeClient(
            replyText: "Milk, eggs, and bread are on the list.\nSPOKEN: You need milk, eggs, and bread.")
        let relay = makeRelay(fake)
        let context = try makeContext()

        let turn = RelayedTurn(requestId: UUID(), text: "What's on the shopping list?", mode: .ask)
        let outcome = await relay.relay(turn, context: context)

        // The result value PR2 ships back to the watch.
        guard case .delivered(let result) = outcome else {
            return XCTFail("expected delivered, got \(outcome)")
        }
        XCTAssertEqual(result.displayText, "Milk, eggs, and bread are on the list.")
        XCTAssertEqual(result.spokenText, "You need milk, eggs, and bread.")
        XCTAssertEqual(result.sessionId, "sess-relay")

        // The thread is tagged .watch and both turns landed in the normal history.
        let threads = try allThreads(context)
        XCTAssertEqual(threads.count, 1)
        let thread = try XCTUnwrap(threads.first)
        XCTAssertEqual(thread.id, result.threadId)
        XCTAssertEqual(thread.originValue, .watch)
        XCTAssertEqual(thread.sessionId, "sess-relay")

        let turns = thread.orderedTurns
        XCTAssertEqual(turns.count, 2)
        XCTAssertEqual(turns.first?.roleValue, .user)
        XCTAssertEqual(turns.first?.text, "What's on the shopping list?")
        XCTAssertEqual(turns.last?.roleValue, .jesse)
        XCTAssertEqual(turns.last?.text, "Milk, eggs, and bread are on the list.")

        XCTAssertEqual(fake.sendCount, 1)
    }

    // MARK: - Deduplication by requestId

    /// Two sequential calls with the SAME requestId run exactly one turn, create
    /// exactly one thread, and return the same outcome — the second is served from
    /// the recently-completed cache.
    @MainActor
    func testDuplicateRequestIdRunsOneTurnSequential() async throws {
        let fake = RelayFakeClient(replyText: "Answer.\nSPOKEN: Answer.")
        let relay = makeRelay(fake)
        let context = try makeContext()

        let turn = RelayedTurn(requestId: UUID(), text: "Same question", mode: .ask)
        let first = await relay.relay(turn, context: context)
        let second = await relay.relay(turn, context: context)

        XCTAssertEqual(fake.sendCount, 1, "a duplicate requestId must not start a second turn")
        XCTAssertEqual(try allThreads(context).count, 1, "a duplicate must not create a second thread")
        XCTAssertEqual(first, second, "a duplicate returns the same outcome")
    }

    /// Two CONCURRENT calls with the same requestId also collapse to one turn — the
    /// second awaits the in-flight task rather than spawning its own.
    @MainActor
    func testDuplicateRequestIdRunsOneTurnConcurrent() async throws {
        let fake = RelayFakeClient(replyText: "Answer.\nSPOKEN: Answer.")
        let relay = makeRelay(fake)
        let context = try makeContext()

        let turn = RelayedTurn(requestId: UUID(), text: "Same question", mode: .ask)
        async let a = relay.relay(turn, context: context)
        async let b = relay.relay(turn, context: context)
        let (first, second) = await (a, b)

        XCTAssertEqual(fake.sendCount, 1)
        XCTAssertEqual(try allThreads(context).count, 1)
        XCTAssertEqual(first, second)
    }

    /// A DIFFERENT requestId is a distinct turn (the dedup is keyed, not a global
    /// lock).
    @MainActor
    func testDistinctRequestIdsRunSeparateTurns() async throws {
        let fake = RelayFakeClient(replyText: "Answer.\nSPOKEN: Answer.")
        let relay = makeRelay(fake)
        let context = try makeContext()

        _ = await relay.relay(RelayedTurn(requestId: UUID(), text: "Q1", mode: .ask), context: context)
        _ = await relay.relay(RelayedTurn(requestId: UUID(), text: "Q2", mode: .tell), context: context)

        XCTAssertEqual(fake.sendCount, 2)
        XCTAssertEqual(try allThreads(context).count, 2)
    }

    // MARK: - Failure yields a clean value, never a throw

    /// A stubbed transport failure at the poll returns a `.failure` value (with the
    /// created thread's id), and never throws into the caller.
    @MainActor
    func testRelayFailureYieldsErrorValue() async throws {
        let fake = RelayFakeClient(replyText: "unused", failAtResult: true)
        let relay = makeRelay(fake)
        let context = try makeContext()

        let turn = RelayedTurn(requestId: UUID(), text: "Will fail", mode: .ask)
        let outcome = await relay.relay(turn, context: context)

        guard case .failure(let message, let threadId) = outcome else {
            return XCTFail("expected failure, got \(outcome)")
        }
        XCTAssertFalse(message.isEmpty)

        // The thread + user turn were still created (not lost); only Jesse's turn
        // is missing because the turn failed.
        let threads = try allThreads(context)
        XCTAssertEqual(threads.count, 1)
        let thread = try XCTUnwrap(threads.first)
        XCTAssertEqual(thread.id, threadId)
        XCTAssertEqual(thread.originValue, .watch)
        XCTAssertEqual(thread.orderedTurns.map(\.roleValue), [.user])
    }

    /// `voice` defaults to true so the reply carries a SPOKEN line to read aloud.
    func testRelayedTurnDefaultsToVoice() {
        let turn = RelayedTurn(requestId: UUID(), text: "hi", mode: .ask)
        XCTAssertTrue(turn.voice)
    }
}
