import XCTest
import SwiftData
@testable import Jesse
import JesseCore
import JesseNetworking

/// The send outbox now retries ITSELF — on a bounded backoff and when the network comes
/// back — where before it waited for a human to tap Retry.
///
/// The whole risk in that is duplication, and it is closed by construction rather than by
/// timing: the item's `id` IS the wire `request_id`, and the bridge dedups on it. What
/// these tests hold to is the other half — that it is BOUNDED, that a manual Retry and the
/// automatic budget do not interfere, and that a network recovery drives the three
/// recoveries together rather than three ways.
@MainActor
final class RunCoordinatorAutoRetryTests: XCTestCase {

    /// Fails every send until `succeedFrom` calls have been made, recording each
    /// `request_id` so a test can assert the key never changes across retries.
    @MainActor
    private final class RetryFakeClient: JesseClientProtocol {
        var failuresRemaining: Int
        private(set) var sendCallCount = 0
        private(set) var requestIds: [UUID] = []

        init(failuresRemaining: Int) { self.failuresRemaining = failuresRemaining }

        func send(mode: JesseMode, text: String, sessionId: String?,
                  conversationId: String, voice: Bool,
                  instructions: String?, floorOverride: String?,
                  attachments: [JesseAttachment], requestId: UUID,
                  model: String?) async throws -> JesseSendResult {
            sendCallCount += 1
            requestIds.append(requestId)
            if failuresRemaining > 0 {
                failuresRemaining -= 1
                throw JesseError.cannotConnect("laptop")
            }
            return .running(jobId: "job-\(sendCallCount)", conversationId: nil)
        }

        func result(jobId: String) async throws -> JesseResultState {
            .done(JesseReply(text: "ok", sessionId: nil))
        }
        func cancelJob(jobId: String) async throws {}
        func stream(jobId: String) -> AsyncThrowingStream<JesseStreamEvent, Error> {
            AsyncThrowingStream { $0.finish() }
        }
    }

    private final class MemoryInFlightStore: InFlightStoring {
        var map: [UUID: InFlightJob]
        init(_ map: [UUID: InFlightJob] = [:]) { self.map = map }
        func load() -> [UUID: InFlightJob] { map }
        func save(_ map: [UUID: InFlightJob]) { self.map = map }
    }

    /// Counts `replayAll()` calls, so the P8 hook is proven to fire on a recovery rather
    /// than merely to exist.
    @MainActor
    private final class CountingReplayer: IntentReplaying {
        private(set) var replays = 0
        func replayAll() async { replays += 1 }
    }

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: JesseThread.self, Turn.self, OutboxItem.self, OutboxAttachment.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return ModelContext(container)
    }

    private func makeCoordinator(_ fake: RetryFakeClient,
                                 now: @escaping @MainActor () -> Date = { Date() },
                                 replayer: (any IntentReplaying)? = nil,
                                 inFlightStore: InFlightStoring? = nil) -> RunCoordinator {
        RunCoordinator(
            config: { JesseConfig(host: "laptop", port: 8765, token: "tok") },
            makeClient: { _ in fake },
            // No real waiting anywhere: the armed-retry timer and the poll loop both go
            // through this seam.
            pollSleep: { _ in await Task.yield() },
            now: now,
            inFlightStore: inFlightStore ?? MemoryInFlightStore(),
            intentReplayer: replayer)
    }

    private func outboxItems(_ context: ModelContext) -> [OutboxItem] {
        (try? context.fetch(FetchDescriptor<OutboxItem>())) ?? []
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 4,
                           _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { XCTFail("timed out waiting for: \(what)"); return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    /// Stage a message and let its send fail, leaving a `.failed` item.
    private func stageFailedMessage(_ coordinator: RunCoordinator,
                                    _ context: ModelContext) async -> OutboxItem {
        let thread = JesseThread(mode: .ask)
        coordinator.send(thread: thread, text: "hi there", voice: false, context: context)
        await waitUntil("the send to fail") {
            self.outboxItems(context).first?.state == .failed
        }
        return outboxItems(context)[0]
    }

    // MARK: - The schedule is recorded on the item

    /// A failure writes the next due date onto the item, so the schedule survives a
    /// relaunch instead of restarting with a fresh budget.
    func testAFailureRecordsWhenItMayTryAgain() async throws {
        let context = try makeContext()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let coordinator = makeCoordinator(RetryFakeClient(failuresRemaining: 99), now: { t0 })
        let item = await stageFailedMessage(coordinator, context)

        XCTAssertEqual(item.automaticAttempts, 0, "nothing automatic has happened yet")
        XCTAssertEqual(item.nextRetryAt, t0.addingTimeInterval(5),
                       "the first automatic retry is five seconds out")
    }

    // MARK: - Due, and not due

    func testAnItemIsNotSentBeforeItsDelayHasElapsed() async throws {
        let context = try makeContext()
        var clock = Date(timeIntervalSince1970: 2_000_000)
        let fake = RetryFakeClient(failuresRemaining: 99)
        let coordinator = makeCoordinator(fake, now: { clock })
        _ = await stageFailedMessage(coordinator, context)
        let after = fake.sendCallCount

        clock = clock.addingTimeInterval(4)
        coordinator.retryDueOutbox(context: context)
        XCTAssertEqual(fake.sendCallCount, after, "four seconds is not five")
    }

    func testAnItemIsSentOnceItsDelayHasElapsed() async throws {
        let context = try makeContext()
        var clock = Date(timeIntervalSince1970: 3_000_000)
        let fake = RetryFakeClient(failuresRemaining: 1)
        let coordinator = makeCoordinator(fake, now: { clock })
        let item = await stageFailedMessage(coordinator, context)
        let key = item.id

        clock = clock.addingTimeInterval(5)
        coordinator.retryDueOutbox(context: context)
        await waitUntil("the automatic retry to be delivered") {
            self.outboxItems(context).isEmpty
        }
        XCTAssertEqual(fake.sendCallCount, 2)
        XCTAssertEqual(fake.requestIds, [key, key],
                       "the retry MUST carry the same request_id — that is the only thing "
                       + "stopping a re-send of a POST that landed from duplicating the turn")
    }

    // MARK: - The cap

    /// Five automatic sends, then it is the button's again. A message that retries forever
    /// against a bridge that will never answer is a flat battery and nothing to show for it.
    func testAutomaticRetriesStopAtFive() async throws {
        let context = try makeContext()
        var clock = Date(timeIntervalSince1970: 4_000_000)
        let fake = RetryFakeClient(failuresRemaining: 99)
        let coordinator = makeCoordinator(fake, now: { clock })
        _ = await stageFailedMessage(coordinator, context)
        let baseline = fake.sendCallCount

        // Drive far past every delay, many times over.
        for _ in 0..<12 {
            clock = clock.addingTimeInterval(3600)
            coordinator.retryDueOutbox(context: context)
            await waitUntil("the retry to settle") {
                self.outboxItems(context).first?.state == .failed
            }
        }
        XCTAssertEqual(fake.sendCallCount - baseline, 5,
                       "exactly five automatic sends, however long we wait")
        let item = outboxItems(context)[0]
        XCTAssertEqual(item.automaticAttempts, 5)
        XCTAssertNil(item.nextRetryAt, "nil is what hands it back to the Retry button")
        XCTAssertEqual(item.state, .failed, "and it is still there to be retried by hand")
    }

    /// A human saying "try again" is a statement that the situation has changed, so the
    /// automatic budget starts over. Tapping Retry therefore never spends an automatic
    /// attempt, and exhausting the automatic attempts never disables the button.
    func testAManualRetryResetsTheAutomaticBudget() async throws {
        let context = try makeContext()
        var clock = Date(timeIntervalSince1970: 5_000_000)
        let fake = RetryFakeClient(failuresRemaining: 99)
        let coordinator = makeCoordinator(fake, now: { clock })
        _ = await stageFailedMessage(coordinator, context)

        clock = clock.addingTimeInterval(5)
        coordinator.retryDueOutbox(context: context)
        await waitUntil("the automatic retry to fail") {
            self.outboxItems(context).first?.state == .failed
        }
        XCTAssertEqual(outboxItems(context)[0].automaticAttempts, 1)

        coordinator.retry(itemID: outboxItems(context)[0].id, context: context)
        await waitUntil("the manual retry to fail") {
            self.outboxItems(context).first?.state == .failed
        }
        XCTAssertEqual(outboxItems(context)[0].automaticAttempts, 0,
                       "a manual Retry resets the automatic budget rather than spending it")
    }

    // MARK: - Recovery on the network coming back

    /// The network returning skips the backoff — the delays exist to avoid hammering a
    /// network that is not there, and that reasoning does not apply to one that just came
    /// back.
    func testANetworkRecoverySendsWithoutWaitingForTheBackoff() async throws {
        let context = try makeContext()
        let clock = Date(timeIntervalSince1970: 6_000_000)
        let fake = RetryFakeClient(failuresRemaining: 1)
        let replayer = CountingReplayer()
        let coordinator = makeCoordinator(fake, now: { clock }, replayer: replayer)
        _ = await stageFailedMessage(coordinator, context)

        // No time has passed at all — the next retry is not due for five seconds.
        coordinator.recoverAfterNetworkReturned(context: context)
        await waitUntil("the recovery send to be delivered") {
            self.outboxItems(context).isEmpty
        }
        XCTAssertEqual(fake.sendCallCount, 2)
        await waitUntil("the intent replay to fire") { replayer.replays >= 1 }
        XCTAssertGreaterThanOrEqual(replayer.replays, 1,
                                    "a queued intent (P8) replays alongside the outbox "
                                    + "drain, not on a timer of its own that races it")
    }

    /// …but a recovery cannot be used to retry without end. A flapping connection is not a
    /// licence.
    func testANetworkRecoveryStillRespectsTheCap() async throws {
        let context = try makeContext()
        var clock = Date(timeIntervalSince1970: 7_000_000)
        let fake = RetryFakeClient(failuresRemaining: 99)
        let coordinator = makeCoordinator(fake, now: { clock })
        _ = await stageFailedMessage(coordinator, context)
        let baseline = fake.sendCallCount

        for _ in 0..<10 {
            clock = clock.addingTimeInterval(1)
            coordinator.recoverAfterNetworkReturned(context: context)
            await waitUntil("the retry to settle") {
                self.outboxItems(context).first?.state == .failed
            }
        }
        XCTAssertEqual(fake.sendCallCount - baseline, 5)
    }

    /// A recovery also re-attaches every persisted in-flight job: the turn kept running on
    /// the laptop the whole time, and this is the app catching up with it.
    func testANetworkRecoveryReattachesInFlightJobs() async throws {
        let context = try makeContext()
        let thread = JesseThread(mode: .ask)
        context.insert(thread)
        try context.save()

        let store = MemoryInFlightStore([thread.id: InFlightJob(jobId: "job-away", voice: false)])
        let fake = RetryFakeClient(failuresRemaining: 0)
        let coordinator = makeCoordinator(fake, inFlightStore: store)
        XCTAssertTrue(coordinator.isRunning(thread.id))

        coordinator.recoverAfterNetworkReturned(context: context)
        await waitUntil("the re-attached job to deliver") {
            !coordinator.isRunning(thread.id)
        }
        XCTAssertEqual(thread.orderedTurns.last?.text, "ok")
        XCTAssertNil(coordinator.error(for: thread.id))
    }
}
