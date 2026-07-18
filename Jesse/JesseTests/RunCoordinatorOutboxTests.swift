import XCTest
import SwiftData
@testable import Jesse

/// The send outbox: a message is persisted at stage time (an `OutboxItem` carrying
/// the ORIGINAL full-resolution attachment bytes) and deleted the instant the bridge
/// ACKs — so a pre-ACK drop (timeout, dead network, 429/5xx, a kill mid-POST) no
/// longer loses it. A failed send is preserved as `.failed` for a MANUAL per-message
/// Retry (never automatic), re-run with the SAME `request_id` so the bridge dedups a
/// POST that actually landed. These tests drive a real `RunCoordinator` + in-memory
/// store through the client seam, asserting the whole stage → ACK/fail → retry →
/// discard lifecycle and the app-killed-mid-POST reconcile.
final class RunCoordinatorOutboxTests: XCTestCase {

    /// A client scripted per `send` call, capturing the `request_id` and attachments
    /// each call carried so a test can assert idempotency across retries and the
    /// original-bytes round-trip. Implements BOTH the plain and `requestId:` sends;
    /// `transmit` always calls the latter.
    @MainActor
    private final class OutboxFakeClient: JesseClientProtocol {
        enum Behavior {
            case failPreACK(JesseError)
            case cancelPreACK
            case running(String)
            case reply(JesseReply)
        }
        /// Consumed per send call; the last entry repeats if there are more calls.
        var behaviors: [Behavior]
        private(set) var sendCallCount = 0
        private(set) var requestIds: [UUID?] = []
        private(set) var sentAttachments: [[JesseAttachment]] = []

        init(_ behaviors: [Behavior]) { self.behaviors = behaviors }

        func send(mode: JesseMode, text: String, sessionId: String?, voice: Bool,
                  instructions: String?, floorOverride: String?,
                  attachments: [JesseAttachment]) async throws -> JesseSendResult {
            try await send(mode: mode, text: text, sessionId: sessionId, voice: voice,
                           instructions: instructions, floorOverride: floorOverride,
                           attachments: attachments, requestId: nil)
        }

        func send(mode: JesseMode, text: String, sessionId: String?, voice: Bool,
                  instructions: String?, floorOverride: String?,
                  attachments: [JesseAttachment], requestId: UUID?) async throws -> JesseSendResult {
            sendCallCount += 1
            requestIds.append(requestId)
            sentAttachments.append(attachments)
            let behavior = behaviors[min(sendCallCount - 1, behaviors.count - 1)]
            switch behavior {
            case .failPreACK(let error): throw error
            case .cancelPreACK: throw CancellationError()
            case .running(let jobId): return .running(jobId: jobId)
            case .reply(let reply): return .reply(reply, jobId: nil)
            }
        }

        // After a 202 ACK, `consume` polls this — resolve immediately so the turn
        // completes cleanly (the outbox delete already happened before consume).
        func result(jobId: String) async throws -> JesseResultState {
            .done(JesseReply(text: "ok", sessionId: nil))
        }
        func cancelJob(jobId: String) async throws {}
        func stream(jobId: String) -> AsyncThrowingStream<JesseStreamEvent, Error> {
            AsyncThrowingStream { $0.finish() }
        }
    }

    /// In-memory `InFlightStoring` so a test can seed the persisted job map (which
    /// `RunCoordinator` loads at init) without touching shared UserDefaults.
    private final class MemoryInFlightStore: InFlightStoring {
        var map: [UUID: InFlightJob]
        init(_ map: [UUID: InFlightJob] = [:]) { self.map = map }
        func load() -> [UUID: InFlightJob] { map }
        func save(_ map: [UUID: InFlightJob]) { self.map = map }
    }

    @MainActor
    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: JesseThread.self, Turn.self, OutboxItem.self, OutboxAttachment.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return ModelContext(container)
    }

    @MainActor
    private func makeCoordinator(_ fake: OutboxFakeClient,
                                 inFlightStore: InFlightStoring? = nil) -> RunCoordinator {
        RunCoordinator(
            config: { JesseConfig(host: "laptop", port: 8765, token: "tok") },
            makeClient: { _ in fake },
            inFlightStore: inFlightStore)
    }

    @MainActor
    private func outboxItems(_ context: ModelContext) -> [OutboxItem] {
        (try? context.fetch(FetchDescriptor<OutboxItem>())) ?? []
    }

    @MainActor
    private func waitUntil(_ what: String, timeout: TimeInterval = 4,
                           _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { XCTFail("timed out waiting for: \(what)"); return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    // MARK: - Stage + ACK deletes the item

    /// Stage persists exactly one `.sending` OutboxItem (synchronously, before the
    /// transmit task runs); the 202 ACK then deletes it.
    @MainActor
    func testStageCreatesItemAnd202ACKDeletesIt() async throws {
        let context = try makeContext()
        let fake = OutboxFakeClient([.running("job-1")])
        let coordinator = makeCoordinator(fake)

        let thread = JesseThread(mode: .ask)
        coordinator.send(thread: thread, text: "hi there", voice: false, context: context)

        // Synchronously after send: the item exists, `.sending`, keyed to the user turn.
        let staged = outboxItems(context)
        XCTAssertEqual(staged.count, 1, "stage creates exactly one outbox item")
        XCTAssertEqual(staged.first?.state, .sending)
        XCTAssertEqual(staged.first?.turnID, thread.turns.first?.id)
        XCTAssertTrue(coordinator.isRunning(thread.id), "a .sending item reads as running")

        await waitUntil("the ACK to delete the item") { self.outboxItems(context).isEmpty }
        XCTAssertTrue(outboxItems(context).isEmpty, "the 202 ACK deletes the outbox item")
        XCTAssertFalse(coordinator.isRunning(thread.id))
        XCTAssertNil(coordinator.error(for: thread.id))
    }

    /// The legacy inline 200 (`.reply`) ACK also deletes the item and delivers.
    @MainActor
    func testLegacyInline200ACKDeletesItem() async throws {
        let context = try makeContext()
        let fake = OutboxFakeClient([.reply(JesseReply(text: "the answer", sessionId: "s1"))])
        let coordinator = makeCoordinator(fake)

        let thread = JesseThread(mode: .ask)
        coordinator.send(thread: thread, text: "hi", voice: false, context: context)
        XCTAssertEqual(outboxItems(context).count, 1)

        await waitUntil("the inline ACK to deliver + delete") {
            self.outboxItems(context).isEmpty && !thread.turns.filter { !$0.isUser }.isEmpty
        }
        XCTAssertTrue(outboxItems(context).isEmpty, "the inline 200 ACK deletes the outbox item")
        XCTAssertEqual(thread.turns.filter { !$0.isUser }.first?.text, "the answer")
        XCTAssertFalse(coordinator.isRunning(thread.id))
    }

    // MARK: - Pre-ACK failure

    /// A pre-ACK throw flips the item to `.failed` with the mapped message and a
    /// bumped attempt count, clears the run, and does NOT set the thread-level banner.
    @MainActor
    func testPreACKFailureMarksItemFailedNoBannerRunCleared() async throws {
        let context = try makeContext()
        let fake = OutboxFakeClient([.failPreACK(.timedOut("laptop"))])
        let coordinator = makeCoordinator(fake)

        let thread = JesseThread(mode: .ask)
        coordinator.send(thread: thread, text: "will fail", voice: false, context: context)

        await waitUntil("the item to fail") { self.outboxItems(context).first?.state == .failed }
        let item = try XCTUnwrap(outboxItems(context).first)
        XCTAssertEqual(item.lastError, JesseError.timedOut("laptop").errorDescription)
        XCTAssertEqual(item.attempts, 1)
        XCTAssertNil(coordinator.error(for: thread.id),
                     "a pre-ACK failure never sets the thread-level banner")
        XCTAssertFalse(coordinator.isRunning(thread.id), "run state cleared")
        XCTAssertNil(coordinator.startDate(for: thread.id))
        XCTAssertEqual(thread.turns.count, 1, "only the optimistic user turn — no reply turn")
    }

    // MARK: - Pre-ACK cancel

    /// A pre-ACK `CancellationError` (today silently cleared, losing the message) now
    /// preserves it as `.failed` with the cancelled message; no thread banner.
    @MainActor
    func testPreACKCancelMarksItemFailedWithCancelledMessage() async throws {
        let context = try makeContext()
        let fake = OutboxFakeClient([.cancelPreACK])
        let coordinator = makeCoordinator(fake)

        let thread = JesseThread(mode: .ask)
        coordinator.send(thread: thread, text: "cancel before delivery", voice: false, context: context)

        await waitUntil("the item to fail as cancelled") {
            self.outboxItems(context).first?.state == .failed
        }
        let item = try XCTUnwrap(outboxItems(context).first)
        XCTAssertEqual(item.lastError, "Cancelled before it was delivered.")
        XCTAssertNil(coordinator.error(for: thread.id))
        XCTAssertFalse(coordinator.isRunning(thread.id))
    }

    // MARK: - Retry

    /// Retry re-runs with the SAME `request_id`, never appends a second user bubble,
    /// increments `attempts`, and — on success — deletes the item.
    @MainActor
    func testRetrySameRequestIdNoDuplicateTurnAttemptsIncrementSuccessDeletes() async throws {
        let context = try makeContext()
        // First two attempts fail pre-ACK; the third ACKs (202).
        let fake = OutboxFakeClient([.failPreACK(.timedOut("laptop")),
                                     .failPreACK(.timedOut("laptop")),
                                     .running("job-r")])
        let coordinator = makeCoordinator(fake)

        let thread = JesseThread(mode: .ask)
        coordinator.send(thread: thread, text: "retry me", voice: false, context: context)

        await waitUntil("first attempt to fail") { self.outboxItems(context).first?.state == .failed }
        let itemID = try XCTUnwrap(outboxItems(context).first).id
        XCTAssertEqual(outboxItems(context).first?.attempts, 1)

        // Retry #1: fails again → attempts 2, still one item, still one user turn.
        coordinator.retry(itemID: itemID, context: context)
        await waitUntil("second attempt to fail") { self.outboxItems(context).first?.attempts == 2 }
        XCTAssertEqual(outboxItems(context).first?.state, .failed)
        XCTAssertEqual(thread.turns.count, 1, "retry never appends a second user bubble")

        // Retry #2: ACKs → the item is deleted and a reply lands.
        coordinator.retry(itemID: itemID, context: context)
        await waitUntil("the successful retry to delete the item") { self.outboxItems(context).isEmpty }

        XCTAssertEqual(thread.turns.count, 2, "one user turn + the delivered reply")
        XCTAssertEqual(fake.sendCallCount, 3)
        // The SAME request_id rode every attempt (idempotency across retries).
        let ids = fake.requestIds.compactMap { $0 }
        XCTAssertEqual(ids.count, 3)
        XCTAssertEqual(Set(ids).count, 1, "the same request_id on the wire across all attempts")
        XCTAssertEqual(ids.first, itemID, "the wire request_id is the OutboxItem.id")
    }

    /// Retry is guarded: it acts ONLY on a `.failed` item — a `.sending` item is a
    /// no-op (no transmit started). Built directly so there's no async send race.
    @MainActor
    func testRetryNoOpOnSendingItem() async throws {
        let context = try makeContext()
        let fake = OutboxFakeClient([.running("job-x")])
        let coordinator = makeCoordinator(fake)

        let thread = JesseThread(mode: .ask)
        context.insert(thread)
        let user = Turn(role: .user, text: "in flight")
        thread.turns.append(user)
        let item = OutboxItem(threadID: thread.id, turnID: user.id, text: "in flight",
                              mode: .ask, voice: false, state: .sending)
        context.insert(item)
        try context.save()

        coordinator.retry(itemID: item.id, context: context)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(fake.sendCallCount, 0, "retry only acts on a .failed item")
        XCTAssertEqual(item.state, .sending, "a .sending item is left untouched")
    }

    // MARK: - Reconcile (app killed mid-POST)

    /// Reconcile: a still-`.sending` item whose thread's persisted job carries a
    /// matching `request_id` is deleted (the ACK won the race with a kill); one with
    /// no matching job is flipped to `.failed` ("Jesse never received this.").
    @MainActor
    func testReconcileDeletesAckWonAndFailsNeverReceived() async throws {
        let context = try makeContext()

        let tACK = UUID(), idACK = UUID()
        let tLost = UUID(), idLost = UUID()

        // Seed the persisted job map so the coordinator loads it at init: only the
        // ACK-won thread has an in-flight job, and its request_id matches its item.
        let store = MemoryInFlightStore([
            tACK: InFlightJob(jobId: "job-ack", voice: false, requestId: idACK)
        ])

        // Two orphaned `.sending` items (no live task — nothing was sent this session).
        let ackItem = OutboxItem(id: idACK, threadID: tACK, turnID: UUID(),
                                 text: "ack won", mode: .ask, voice: false)
        let lostItem = OutboxItem(id: idLost, threadID: tLost, turnID: UUID(),
                                  text: "never received", mode: .ask, voice: false)
        context.insert(ackItem)
        context.insert(lostItem)
        try context.save()

        let coordinator = makeCoordinator(OutboxFakeClient([]), inFlightStore: store)
        coordinator.reconcile(context: context)

        let items = outboxItems(context)
        XCTAssertNil(items.first { $0.id == idACK }, "the ACK-won item is deleted as stale")
        let lost = try XCTUnwrap(items.first { $0.id == idLost })
        XCTAssertEqual(lost.state, .failed)
        XCTAssertEqual(lost.lastError, "Jesse never received this.")
    }

    // MARK: - Discard

    /// Discard removes the item and its user turn; an empty, sessionless thread is
    /// deleted, while a thread with other history survives.
    @MainActor
    func testDiscardRemovesTurnDeletesEmptyThreadKeepsThreadWithHistory() async throws {
        let context = try makeContext()

        // Thread A: only the failed message, no session → deleted on discard.
        let threadA = JesseThread(mode: .ask)
        context.insert(threadA)
        let userA = Turn(role: .user, text: "lone message")
        threadA.turns.append(userA)
        let itemA = OutboxItem(threadID: threadA.id, turnID: userA.id, text: "lone message",
                               mode: .ask, voice: false, state: .failed)
        context.insert(itemA)

        // Thread B: has prior history → survives; only its newest user turn is removed.
        let threadB = JesseThread(mode: .ask)
        context.insert(threadB)
        let priorUser = Turn(role: .user, text: "earlier")
        let priorReply = Turn(role: .jesse, text: "an earlier reply")
        threadB.turns.append(priorUser)
        threadB.turns.append(priorReply)
        let newUser = Turn(role: .user, text: "failed follow-up")
        threadB.turns.append(newUser)
        let itemB = OutboxItem(threadID: threadB.id, turnID: newUser.id, text: "failed follow-up",
                               mode: .ask, voice: false, state: .failed)
        context.insert(itemB)
        try context.save()

        let coordinator = makeCoordinator(OutboxFakeClient([]))
        let idA = threadA.id, idB = threadB.id

        coordinator.discard(itemID: itemA.id, context: context)
        coordinator.discard(itemID: itemB.id, context: context)

        // Thread A gone entirely.
        let threadsLeft = (try? context.fetch(FetchDescriptor<JesseThread>())) ?? []
        XCTAssertNil(threadsLeft.first { $0.id == idA }, "an empty sessionless thread is deleted")
        // Thread B survived with only its history (the failed follow-up turn removed).
        let survivor = try XCTUnwrap(threadsLeft.first { $0.id == idB })
        XCTAssertEqual(survivor.orderedTurns.map(\.text), ["earlier", "an earlier reply"],
                       "the discarded user turn is removed; prior history survives")
        XCTAssertTrue(outboxItems(context).isEmpty, "both outbox items are gone")
    }

    // MARK: - Attachments round-trip

    /// The ORIGINAL full-resolution bytes round-trip through `OutboxAttachment`, ride
    /// the wire on every attempt, and are gone once the item is deleted at ACK.
    @MainActor
    func testAttachmentOriginalBytesRoundTripRetryReencodesAndGoneAfterACK() async throws {
        let context = try makeContext()
        let original = Data((0..<512).map { UInt8($0 % 251) })
        let attachment = JesseAttachment(filename: "photo.jpg", mime: "image/jpeg", data: original)
        // Fail first (so the item persists for inspection), then ACK on retry.
        let fake = OutboxFakeClient([.failPreACK(.timedOut("laptop")), .running("job-a")])
        let coordinator = makeCoordinator(fake)

        let thread = JesseThread(mode: .ask)
        coordinator.send(thread: thread, text: "with a photo", voice: false, context: context,
                         attachments: [attachment])

        await waitUntil("the send to fail") { self.outboxItems(context).first?.state == .failed }
        // The ORIGINAL bytes persisted on the OutboxItem, and rode the first POST.
        let item = try XCTUnwrap(outboxItems(context).first)
        XCTAssertEqual(item.orderedAttachments.first?.data, original,
                       "the ORIGINAL bytes round-trip through OutboxAttachment")
        XCTAssertEqual(fake.sentAttachments.first?.first?.data, original)

        // Retry re-encodes the SAME bytes on the wire, then the ACK deletes the item.
        coordinator.retry(itemID: item.id, context: context)
        await waitUntil("the retry to ACK and delete the item") { self.outboxItems(context).isEmpty }
        XCTAssertEqual(fake.sentAttachments.count, 2)
        XCTAssertEqual(fake.sentAttachments.last?.first?.data, original,
                       "a retried send re-encodes the same original bytes")
        XCTAssertTrue(outboxItems(context).isEmpty, "the attachment bytes are gone after ACK")
    }
}
