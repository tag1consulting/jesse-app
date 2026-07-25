import XCTest
import SwiftData
@testable import Jesse
import JesseCore

/// Item 2 — the watch relay entry point. Drives the relay end-to-end as plain
/// TEXT (no watch hardware) through the same `JesseClientProtocol` seam the
/// `RunCoordinator` tests use, asserting: one turn runs per `requestId`
/// (deduplication), the created thread is tagged `.watch`, BOTH turns persist to
/// the real store, the result carries displayText/spokenText from a stubbed reply,
/// and a stubbed failure yields a clean error value rather than a throw.
@MainActor
final class WatchRelayTests: XCTestCase {

    /// A fake client that counts sends and returns a fixed reply (or fails at the
    /// `result` poll). No live stream — it finishes immediately so completion is
    /// driven by the poll, the authoritative path (as in `RunCoordinatorFinishTests`).
    @MainActor
    private final class RelayFakeClient: JesseClientProtocol {
        var sendCount = 0
        private(set) var sentRequestIds: [UUID] = []
        private(set) var sentConversationIds: [String] = []
        let replyText: String
        let sessionId: String?
        let failAtResult: Bool

        init(replyText: String, sessionId: String? = "sess-relay", failAtResult: Bool = false) {
            self.replyText = replyText
            self.sessionId = sessionId
            self.failAtResult = failAtResult
        }

        func send(mode: JesseMode, text: String, sessionId: String?,
                  conversationId: String, voice: Bool,
                  instructions: String?, floorOverride: String?,
                  attachments: [JesseAttachment], requestId: UUID,
                  model: String?) async throws -> JesseSendResult {
            sendCount += 1
            sentRequestIds.append(requestId)
            sentConversationIds.append(conversationId)
            // Echo the id back the way the bridge does, so the acceptance path is exercised.
            return .running(jobId: "job-relay", conversationId: conversationId)
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
    private func makeRelay(_ fake: RelayFakeClient,
                           relayedStore: RelayedTurnStore = RelayedTurnStore(
                            defaults: UserDefaults(suiteName: "WatchRelayTests.\(UUID().uuidString)")!))
        -> WatchRelay {
        let coordinator = RunCoordinator(
            config: { JesseConfig(host: "laptop", port: 8765, token: "tok") },
            makeClient: { _ in fake },
            pollSleep: { _ in })   // no real waiting; result resolves on first poll
        return WatchRelay(coordinator: coordinator, relayedStore: relayedStore)
    }

    private func scratchRelayedStore() -> RelayedTurnStore {
        RelayedTurnStore(defaults: UserDefaults(suiteName: "WatchRelayTests.\(UUID().uuidString)")!)
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
        // `relay` is `@MainActor`, so both calls run on the main actor and interleave
        // at their `await`s — which is exactly the coalescing path under test. Drive
        // them through two main-actor tasks (rather than `async let`, whose nonisolated
        // child tasks would require sending the non-Sendable `ModelContext` across an
        // isolation boundary); the context stays on the main actor throughout.
        let a = Task { @MainActor in await relay.relay(turn, context: context) }
        let b = Task { @MainActor in await relay.relay(turn, context: context) }
        let (first, second) = (await a.value, await b.value)

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

    // MARK: - Durable dedup across an app relaunch

    @MainActor
    func testWatchRelayRedeliveryAfterRelaunchReusesTheExistingConversation() async throws {
        // The bug this closes: `inFlight` and `completed` are IN MEMORY, so a
        // `transferUserInfo` redelivered after the phone app was killed and relaunched found
        // both maps empty and constructed a SECOND thread for the same utterance. Two relay
        // instances over ONE durable store is exactly that relaunch.
        let store = scratchRelayedStore()
        let context = try makeContext()
        let fake = RelayFakeClient(replyText: "the answer\nSPOKEN: the answer")
        let id = UUID()
        let turn = RelayedTurn(requestId: id, text: "what is on the list", mode: .ask)

        let first = makeRelay(fake, relayedStore: store)
        let outcome = await first.relay(turn, context: context)
        guard case .delivered(let result) = outcome else { return XCTFail("expected delivery") }
        XCTAssertEqual(try allThreads(context).count, 1)
        XCTAssertEqual(fake.sendCount, 1)

        // The app is killed and relaunched: a brand-new relay with empty in-memory maps.
        let afterRelaunch = makeRelay(fake, relayedStore: store)
        let redelivered = await afterRelaunch.relay(turn, context: context)

        XCTAssertEqual(try allThreads(context).count, 1,
                       "a redelivery after relaunch must NOT create a second conversation")
        XCTAssertEqual(fake.sendCount, 1, "and must not run a second turn")
        guard case .delivered(let again) = redelivered else { return XCTFail("expected delivery") }
        XCTAssertEqual(again.threadId, result.threadId, "it resolves to the SAME thread")
    }

    @MainActor
    func testWatchRelaySendsANonNilRequestId() async throws {
        // The relay used to send no `request_id` at all, which disabled the bridge's own
        // idempotency for exactly the traffic most likely to be redelivered. The utterance's
        // id IS the request id.
        let context = try makeContext()
        let fake = RelayFakeClient(replyText: "ok\nSPOKEN: ok")
        let relay = makeRelay(fake)
        let id = UUID()

        _ = await relay.relay(RelayedTurn(requestId: id, text: "hello", mode: .ask), context: context)

        XCTAssertEqual(fake.sentRequestIds, [id],
                       "the relayed turn carries the utterance id as the bridge request_id")
        let cid = try XCTUnwrap(fake.sentConversationIds.first)
        XCTAssertFalse(cid.isEmpty, "and it carries the destination thread's conversation id")
        XCTAssertEqual(try allThreads(context).first?.conversationId, cid)
    }

    @MainActor
    func testRelayReportsBridgeAcceptanceToTheCaller() async throws {
        // The acceptance seam the watch's "Received" state reads. `runRelayTurn` only returns
        // after the whole poll, so without this callback there is no acceptance moment at all.
        let context = try makeContext()
        let fake = RelayFakeClient(replyText: "ok\nSPOKEN: ok")
        let relay = makeRelay(fake)
        var accepted: [String] = []

        _ = await relay.relay(RelayedTurn(requestId: UUID(), text: "hello", mode: .ask),
                              context: context, onAccepted: { accepted.append($0) })

        XCTAssertEqual(accepted.count, 1, "acceptance is reported exactly once")
        XCTAssertEqual(accepted.first, try allThreads(context).first?.conversationId,
                       "and names the conversation the turn landed in")
    }

    @MainActor
    func testRelayedTurnStoreIsBoundedAndIdempotent() {
        let store = scratchRelayedStore()
        let first = UUID()
        store.remember(RelayedTurnRecord(requestId: first, threadID: UUID(),
                                        conversationId: "c1", recordedAt: Date()))
        // Re-recording keeps the original entry rather than duplicating it.
        store.remember(RelayedTurnRecord(requestId: first, threadID: UUID(),
                                        conversationId: "c-other", recordedAt: Date()))
        XCTAssertEqual(store.all.count, 1)
        XCTAssertEqual(store.record(first)?.conversationId, "c1")

        // FIFO-bounded: the window only needs to cover a redelivery burst plus a relaunch.
        for _ in 0..<(RelayedTurnStore.cap + 10) {
            store.remember(RelayedTurnRecord(requestId: UUID(), threadID: UUID(),
                                            conversationId: "c", recordedAt: Date()))
        }
        XCTAssertEqual(store.all.count, RelayedTurnStore.cap)
        XCTAssertNil(store.record(first), "the oldest entries are evicted")
    }
}
