import XCTest
import SwiftData
@testable import Jesse
import JesseCore
import JesseNetworking

/// Being woken WITHOUT being opened. The app had no `UIBackgroundModes` at all before
/// this, so a reply that finished while the phone was in a pocket sat on the laptop until
/// the app was next opened — the push carried the `job_id` the whole time and nothing was
/// allowed to act on it.
///
/// Everything important here is about the SECOND wake-up: a push can be delivered more
/// than once for the same job, and the refresh task can fire while one is being handled.
/// So delivery has to be idempotent, and the way to be sure is to send the same push twice.
@MainActor
final class BackgroundDeliveryTests: XCTestCase {

    /// Answers `result(jobId:)` from a script and counts the calls.
    @MainActor
    private final class BackgroundFakeClient: JesseClientProtocol {
        var states: [String: JesseResultState] = [:]
        var failResult = false
        private(set) var resultCalls: [String] = []
        private(set) var dietFetches = 0

        func send(mode: JesseMode, text: String, sessionId: String?,
                  conversationId: String, voice: Bool,
                  instructions: String?, floorOverride: String?,
                  attachments: [JesseAttachment], requestId: UUID,
                  model: String?) async throws -> JesseSendResult {
            XCTFail("the background path must never START a turn")
            throw JesseError.notConfigured
        }
        func result(jobId: String) async throws -> JesseResultState {
            resultCalls.append(jobId)
            if failResult { throw JesseError.cannotConnect("laptop") }
            return states[jobId] ?? .expired
        }
        func cancelJob(jobId: String) async throws {}
        func stream(jobId: String) -> AsyncThrowingStream<JesseStreamEvent, Error> {
            AsyncThrowingStream { $0.finish() }
        }
        func fetchDietSnapshot(date: String?) async throws -> DietSnapshot {
            dietFetches += 1
            throw DietFetchError.endpointMissing
        }
    }

    private final class MemoryInFlightStore: InFlightStoring {
        var map: [UUID: InFlightJob]
        init(_ map: [UUID: InFlightJob] = [:]) { self.map = map }
        func load() -> [UUID: InFlightJob] { map }
        func save(_ map: [UUID: InFlightJob]) { self.map = map }
    }

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: JesseThread.self, Turn.self, OutboxItem.self, OutboxAttachment.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return ModelContext(container)
    }

    private func makeDelivery(_ fake: BackgroundFakeClient, _ context: ModelContext,
                              store: InFlightStoring) -> BackgroundDelivery {
        BackgroundDelivery(makeClient: { fake },
                           makeTodayClient: { nil },
                           context: { context },
                           inFlightStore: store,
                           pushWatchSummary: { _ in })
    }

    // MARK: - Delivering a reply

    /// The case the whole feature exists for: the phone is locked, the turn finishes, and
    /// the reply lands in the transcript without anyone opening anything.
    func testAPushDeliversTheReplyIntoItsThread() async throws {
        let context = try makeContext()
        let thread = JesseThread(mode: .ask)
        context.insert(thread)
        try context.save()

        let fake = BackgroundFakeClient()
        fake.states["job-1"] = .done(JesseReply(text: "the answer", sessionId: "s1"))
        let store = MemoryInFlightStore([thread.id: InFlightJob(jobId: "job-1", voice: false)])
        let delivery = makeDelivery(fake, context, store: store)

        let outcome = await delivery.handle(userInfo: ["job_id": "job-1"])
        XCTAssertEqual(outcome, .newData)
        XCTAssertEqual(thread.orderedTurns.last?.text, "the answer")
        XCTAssertEqual(thread.sessionId, "s1")
        XCTAssertTrue(store.map.isEmpty, "a delivered job is dropped from the persisted map")
    }

    /// A push can be delivered more than once. The second must not append a second bubble
    /// — and it does not, because delivery goes through the SAME `TurnWriter` the
    /// foreground uses, which keys on `lastDeliveredJobId`.
    func testASecondPushForTheSameJobDeliversNothingTwice() async throws {
        let context = try makeContext()
        let thread = JesseThread(mode: .ask)
        context.insert(thread)
        try context.save()

        let fake = BackgroundFakeClient()
        fake.states["job-1"] = .done(JesseReply(text: "the answer", sessionId: nil))
        let store = MemoryInFlightStore([thread.id: InFlightJob(jobId: "job-1", voice: false)])
        let delivery = makeDelivery(fake, context, store: store)

        _ = await delivery.handle(userInfo: ["job_id": "job-1"])
        let second = await delivery.handle(userInfo: ["job_id": "job-1"])

        XCTAssertEqual(thread.orderedTurns.filter { !$0.isUser }.count, 1,
                       "exactly one reply bubble, however many pushes arrive")
        XCTAssertEqual(second, .noData)
        XCTAssertEqual(fake.resultCalls, ["job-1"],
                       "the second push does not even re-fetch: the job is already gone "
                       + "from the persisted map, which IS the record of delivery")
    }

    /// A turn still running is not a failure and not new data. Reporting either would
    /// mislead iOS, which budgets future wake-ups on what it is told.
    func testAStillRunningTurnReportsNoDataAndKeepsTheJob() async throws {
        let context = try makeContext()
        let thread = JesseThread(mode: .ask)
        context.insert(thread)
        try context.save()

        let fake = BackgroundFakeClient()
        fake.states["job-1"] = .running
        let store = MemoryInFlightStore([thread.id: InFlightJob(jobId: "job-1", voice: false)])
        let delivery = makeDelivery(fake, context, store: store)

        let outcome = await delivery.handle(userInfo: ["job_id": "job-1"])
        XCTAssertEqual(outcome, .noData)
        XCTAssertEqual(store.map.count, 1, "the job stays for the foreground to pick up")
    }

    /// A fetch that could not complete is reported as `failed`, honestly, rather than as a
    /// quiet nothing.
    func testAFailedFetchIsReportedAsFailed() async throws {
        let context = try makeContext()
        let thread = JesseThread(mode: .ask)
        context.insert(thread)
        try context.save()

        let fake = BackgroundFakeClient()
        fake.failResult = true
        let store = MemoryInFlightStore([thread.id: InFlightJob(jobId: "job-1", voice: false)])
        let delivery = makeDelivery(fake, context, store: store)

        let outcome = await delivery.handle(userInfo: ["job_id": "job-1"])
        XCTAssertEqual(outcome, .failed)
        XCTAssertEqual(store.map.count, 1, "and the job is retained, not lost")
    }

    /// A terminal FAILURE is left to the foreground. The error banner, the Re-check
    /// affordance and the expired copy all live there, and inventing a second delivery of
    /// a failure out here would mean two places decide what a failed turn looks like.
    func testATerminalFailureIsLeftToTheForeground() async throws {
        let context = try makeContext()
        let thread = JesseThread(mode: .ask)
        context.insert(thread)
        try context.save()

        let fake = BackgroundFakeClient()
        fake.states["job-1"] = .failed("the vault is locked")
        let store = MemoryInFlightStore([thread.id: InFlightJob(jobId: "job-1", voice: false)])
        let delivery = makeDelivery(fake, context, store: store)

        let outcome = await delivery.handle(userInfo: ["job_id": "job-1"])
        XCTAssertEqual(outcome, .noData)
        XCTAssertEqual(store.map.count, 1)
        XCTAssertTrue(thread.orderedTurns.isEmpty, "nothing is written for a failure")
    }

    /// A push for a job this device has never held is not an error — it is a re-delivery
    /// of one already handled, or a conversation from another device.
    func testAnUnknownJobIsIgnored() async throws {
        let context = try makeContext()
        let fake = BackgroundFakeClient()
        let delivery = makeDelivery(fake, context, store: MemoryInFlightStore())
        let outcome = await delivery.handle(userInfo: ["job_id": "who?"])
        XCTAssertEqual(outcome, .noData)
        XCTAssertTrue(fake.resultCalls.isEmpty)
    }

    /// The outbox row a killed-mid-POST send left behind is cleared by the same rule
    /// `reconcile` uses: a persisted job carrying this request id means the ACK won.
    func testDeliveryClearsAStaleOutboxRow() async throws {
        let context = try makeContext()
        let thread = JesseThread(mode: .ask)
        context.insert(thread)
        let item = OutboxItem(threadID: thread.id, turnID: UUID(), text: "hi",
                              mode: .ask, voice: false)
        context.insert(item)
        try context.save()

        let fake = BackgroundFakeClient()
        fake.states["job-1"] = .done(JesseReply(text: "the answer", sessionId: nil))
        let store = MemoryInFlightStore([
            thread.id: InFlightJob(jobId: "job-1", voice: false, requestId: item.id)])
        let delivery = makeDelivery(fake, context, store: store)

        _ = await delivery.handle(userInfo: ["job_id": "job-1"])
        let remaining = (try? context.fetch(FetchDescriptor<OutboxItem>())) ?? []
        XCTAssertTrue(remaining.isEmpty, "the ACK won the race, so the row is stale")
    }

    // MARK: - The prefetch payload

    /// A push payload is the least trustworthy dictionary the app ever reads, so the
    /// shapes it must refuse are stated as directly as the one it accepts.
    func testPrefetchParsingAcceptsOnlyKnownNamesInAnArray() {
        XCTAssertEqual(BackgroundDelivery.requestedSnapshots(["today", "diet"]), [.today, .diet])
        XCTAssertEqual(BackgroundDelivery.requestedSnapshots(["diet"]), [.diet])
        XCTAssertEqual(BackgroundDelivery.requestedSnapshots(["today", "today"]), [.today],
                       "a repeat is not two refreshes")
        XCTAssertEqual(BackgroundDelivery.requestedSnapshots(["today", "weather"]), [.today],
                       "an unknown name is dropped, not an error: the bridge is free to "
                       + "learn a third document before this app build does")
        XCTAssertTrue(BackgroundDelivery.requestedSnapshots(nil).isEmpty,
                      "every push before bridge 0.95.0 carries no such key")
        XCTAssertTrue(BackgroundDelivery.requestedSnapshots("today").isEmpty, "a bare string")
        XCTAssertTrue(BackgroundDelivery.requestedSnapshots(42).isEmpty)
        XCTAssertTrue(BackgroundDelivery.requestedSnapshots([["today"]]).isEmpty, "nested")
        XCTAssertTrue(BackgroundDelivery.requestedSnapshots([]).isEmpty)
    }

    /// The payload is parsed ONCE, at the delegate's synchronous entry, so nothing but a
    /// checked `Sendable` value crosses into the background work — a push's `userInfo` is
    /// `[AnyHashable: Any]` and has no business travelling further than that line.
    func testPayloadParsingNormalisesWhatItAccepts() {
        let full = BackgroundDelivery.Payload(userInfo: ["job_id": " j1 ",
                                                         "prefetch": ["today", "diet"]])
        XCTAssertEqual(full.jobId, "j1", "trimmed")
        XCTAssertEqual(full.snapshots, [.today, .diet])
        XCTAssertFalse(full.isEmpty)

        let blank = BackgroundDelivery.Payload(userInfo: ["job_id": "   "])
        XCTAssertNil(blank.jobId, "a whitespace job id is no job id")
        XCTAssertTrue(blank.isEmpty)

        let alertOnly = BackgroundDelivery.Payload(userInfo: ["aps": ["alert": "hi"]])
        XCTAssertTrue(alertOnly.isEmpty,
                      "a push whose only content is an alert is perfectly ordinary, not an error")

        let wrongType = BackgroundDelivery.Payload(userInfo: ["job_id": 42])
        XCTAssertNil(wrongType.jobId)
    }

    /// A payload with neither half does nothing at all, rather than making a round trip to
    /// find that out.
    func testAPayloadWithNothingToDoDoesNothing() async throws {
        let context = try makeContext()
        let fake = BackgroundFakeClient()
        let delivery = makeDelivery(fake, context, store: MemoryInFlightStore())
        let outcome = await delivery.handle(userInfo: ["aps": ["alert": "hi"]])
        XCTAssertEqual(outcome, .noData)
        XCTAssertTrue(fake.resultCalls.isEmpty)
        XCTAssertEqual(fake.dietFetches, 0)
    }

    /// A scheduled-outcome push does BOTH halves when it carries both.
    func testAPushCanDeliverAReplyAndPrefetchAtOnce() async throws {
        let context = try makeContext()
        let thread = JesseThread(mode: .ask)
        context.insert(thread)
        try context.save()

        let fake = BackgroundFakeClient()
        fake.states["job-1"] = .done(JesseReply(text: "morning", sessionId: nil))
        let store = MemoryInFlightStore([thread.id: InFlightJob(jobId: "job-1", voice: false)])
        let delivery = makeDelivery(fake, context, store: store)

        let outcome = await delivery.handle(userInfo: ["job_id": "job-1",
                                                       "prefetch": ["diet"]])
        XCTAssertEqual(outcome, .newData)
        XCTAssertEqual(thread.orderedTurns.last?.text, "morning")
        XCTAssertEqual(fake.dietFetches, 1)
    }

    // MARK: - Reporting the outcome

    /// `newData` wins over everything (something did land) and `failed` beats `noData`, so
    /// a wake-up where half the work broke is not reported to iOS as a quiet nothing.
    func testOutcomeCombining() {
        XCTAssertEqual(BackgroundDelivery.combine(.newData, .failed), .newData)
        XCTAssertEqual(BackgroundDelivery.combine(.failed, .newData), .newData)
        XCTAssertEqual(BackgroundDelivery.combine(.noData, .failed), .failed)
        XCTAssertEqual(BackgroundDelivery.combine(.failed, .noData), .failed)
        XCTAssertEqual(BackgroundDelivery.combine(.noData, .noData), .noData)
        XCTAssertEqual(BackgroundDelivery.combine(.newData, .newData), .newData)
    }
}
