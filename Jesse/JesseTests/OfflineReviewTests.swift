import XCTest
import SwiftData
@testable import Jesse
import JesseCore
import JesseVault

/// **Nothing said offline vanishes.**
///
/// On 2026-09-26, on a phone with the bridge unreachable, "Track two cups of coffee. 6:50
/// and 7:20." was answered by the on-device model with a café's opening hours and queued for
/// nobody: an ANSWERED offline exchange was recorded in memory only and only ever rode a
/// message Jeremy happened to send next. Three candidate paths could drop that record, and
/// the one that did was `finishOnDevice` — a follow-up sent while reachability still read
/// `.unreachable` is routed on-device, the device cannot answer it, and the question it
/// queued went to the bridge with nothing attached.
///
/// These tests drive the whole path: the review is staged as its own outbox item in the same
/// save as the reply, it survives a relaunch, and a conversation's messages reach the bridge
/// in the order they were staged.
@MainActor
final class OfflineReviewTests: XCTestCase {

    // MARK: - Fakes

    /// The bridge, with a switch for whether it is there. Records the text of every send it
    /// ACCEPTED, which is the order the bridge actually saw.
    @MainActor
    private final class ReviewFakeClient: JesseClientProtocol {
        var online = false
        private(set) var accepted: [String] = []
        private(set) var attempted: [String] = []

        func send(mode: JesseMode, text: String, sessionId: String?,
                  conversationId: String, voice: Bool,
                  instructions: String?, floorOverride: String?,
                  attachments: [JesseAttachment], requestId: UUID,
                  model: String?, effort: String?) async throws -> JesseSendResult {
            attempted.append(text)
            guard online else { throw JesseError.timedOut("laptop") }
            accepted.append(text)
            return .running(jobId: "job-\(accepted.count)", conversationId: nil)
        }

        func result(jobId: String) async throws -> JesseResultState {
            .done(JesseReply(text: "ok", sessionId: nil))
        }
        func cancelJob(jobId: String) async throws {}
        func stream(jobId: String) -> AsyncThrowingStream<JesseStreamEvent, Error> {
            AsyncThrowingStream { $0.finish() }
        }
    }

    /// The device's own half of a send. THE GATE IS THE REAL ONE — a fake that decided for
    /// itself which questions are lookups would be testing the fake — and only the answer a
    /// passing question gets is scripted. A question with no scripted answer abstains, which
    /// is what the notes on a device not holding it produces.
    @MainActor
    private final class FakeOffline: OfflineAnswering {
        var decision: OfflineSendRoute = .onDevice
        var answers: [String: VaultAnswer] = [:]
        private(set) var asked: [String] = []

        func route(reachability: BridgeReachabilityState) -> OfflineSendRoute {
            reachability == .unreachable ? decision : .bridge
        }

        func answer(_ question: String) async -> VaultAnswerOutcome {
            asked.append(question)
            if case .refused(let refusal) = LookupGate.rule(question) {
                return .unanswered(.gateRefused(refusal))
            }
            guard let found = answers[question] else { return .unanswered(.abstained) }
            return .answered(found)
        }
    }

    private final class MemoryInFlightStore: InFlightStoring {
        var map: [UUID: InFlightJob] = [:]
        func load() -> [UUID: InFlightJob] { map }
        func save(_ map: [UUID: InFlightJob]) { self.map = map }
    }

    /// Reachability as a value a test can turn, since the whole scenario is about what happens
    /// on either side of it changing.
    private final class Reach {
        var state: BridgeReachabilityState = .unreachable
    }

    // MARK: - Fixtures

    private func memoryContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: JesseThread.self, Turn.self, OutboxItem.self, OutboxAttachment.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return ModelContext(container)
    }

    /// A store ON DISK, so "relaunch" can mean what it means: a second container over the same
    /// file, with nothing carried over in memory.
    private func onDiskStoreURL() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("offline-review-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir.appendingPathComponent("store.sqlite")
    }

    private func store(at url: URL) throws -> ModelContext {
        let container = try ModelContainer(
            for: JesseThread.self, Turn.self, OutboxItem.self, OutboxAttachment.self,
            configurations: ModelConfiguration(url: url))
        return ModelContext(container)
    }

    private func coordinator(_ client: ReviewFakeClient, _ offline: FakeOffline, _ reach: Reach,
                             pollSleep: (@MainActor (TimeInterval) async -> Void)? = nil)
        -> RunCoordinator {
        RunCoordinator(
            config: { JesseConfig(host: "laptop", port: 8765, token: "tok") },
            makeClient: { _ in client },
            pollSleep: pollSleep ?? { try? await Task.sleep(for: .seconds($0)) },
            inFlightStore: MemoryInFlightStore(),
            offline: offline,
            reachability: { reach.state })
    }

    private func items(_ context: ModelContext) -> [OutboxItem] {
        ((try? context.fetch(FetchDescriptor<OutboxItem>())) ?? [])
            .sorted { $0.createdAt < $1.createdAt }
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 6,
                           _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { XCTFail("timed out waiting for: \(what)"); return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    private let born = VaultAnswer(
        text: "You were born on 4 September 1974.",
        citations: [VaultCitation(path: "Biography/Jeremy/Overview.md", line: 3)])

    private let coffee = "Track two cups of coffee. 6:50 and 7:20."

    // MARK: - An answered exchange is sent by itself

    /// The defect, stated as the thing that must now be on disk: the device answered, and
    /// there is a message for the bridge because of it, with nothing new typed.
    func testAnAnsweredOfflineExchangeStagesItsOwnReviewItem() async throws {
        let context = try memoryContext()
        let client = ReviewFakeClient()
        let offline = FakeOffline()
        offline.answers["When was I born?"] = born
        let c = coordinator(client, offline, Reach())

        let thread = JesseThread(mode: .ask)
        c.send(thread: thread, text: "When was I born?", voice: false, context: context)
        await waitUntil("the device to answer and stage its review") {
            !self.items(context).isEmpty
        }

        let review = try XCTUnwrap(items(context).first)
        XCTAssertTrue(review.isOfflineReview, "the review is marked as one")
        XCTAssertTrue(review.text.contains("Q: When was I born?"))
        XCTAssertTrue(review.text.contains("A: You were born on 4 September 1974."))
        XCTAssertTrue(review.text.hasPrefix(OfflineAnswerCarry.preamble),
                      "it opens with the review framing, not with a question")
        XCTAssertFalse(OfflineAnswerCarry.decode(review.offlineReviewPairs).isEmpty,
                       "the pairs are stored, so a later answer can be appended")

        // In the transcript it is labelled, not passed off as something Jeremy typed.
        let turn = try XCTUnwrap(thread.turns.first { $0.id == review.turnID })
        XCTAssertTrue(turn.isUser)
        XCTAssertEqual(turn.displayText, "", "no typed half to show")
        XCTAssertEqual(turn.contextLabel, OfflineAnswerCarry.title)
        XCTAssertEqual(turn.visibleText, "")
    }

    /// One review per conversation, however many questions it answered: a reconnect owes the
    /// bridge one turn, not a queue of them.
    func testASecondAnsweredExchangeIsAppendedToTheSameReviewItem() async throws {
        let context = try memoryContext()
        let client = ReviewFakeClient()
        let offline = FakeOffline()
        offline.answers["When was I born?"] = born
        offline.answers["Whose birthday is in May?"] = VaultAnswer(
            text: "Aurora's, on 12 May.",
            citations: [VaultCitation(path: "Reminders/Family-Dates.md", line: 2)])
        let c = coordinator(client, offline, Reach())

        let thread = JesseThread(mode: .ask)
        c.send(thread: thread, text: "When was I born?", voice: false, context: context)
        // Staged AND its first attempt spent against the absent bridge: the conversation reads
        // as running until that transmit settles, and a send on a running conversation is
        // refused, so waiting only for the item to exist would race it.
        await waitUntil("the first review to be staged and to fail against nothing") {
            self.items(context).first?.state == .failed
        }
        let firstID = items(context).first?.id

        c.send(thread: thread, text: "Whose birthday is in May?", voice: false, context: context)
        await waitUntil("the second answer to be appended") {
            self.items(context).first?.text.contains("Aurora's") == true
        }

        XCTAssertEqual(items(context).count, 1, "one review per conversation")
        let review = try XCTUnwrap(items(context).first)
        XCTAssertEqual(review.id, firstID, "the same item, grown")
        XCTAssertTrue(review.text.contains("Q: When was I born?"))
        XCTAssertTrue(review.text.contains("Q: Whose birthday is in May?"))
        // The transcript's copy grew with it — the turn IS the message.
        let turn = try XCTUnwrap(thread.turns.first { $0.id == review.turnID })
        XCTAssertEqual(turn.text, review.text)
        XCTAssertEqual(thread.turns.filter { $0.contextLabel == OfflineAnswerCarry.title }.count,
                       1)
    }

    /// The gate half, end to end through the coordinator: the coffee sentence is refused by the
    /// device and queued for the bridge, with the clause the device checklist quotes.
    func testTheCoffeeSentenceIsRefusedAndQueuedRatherThanAnswered() async throws {
        let context = try memoryContext()
        let client = ReviewFakeClient()
        let c = coordinator(client, FakeOffline(), Reach())

        let thread = JesseThread(mode: .ask)
        c.send(thread: thread, text: coffee, voice: false, context: context)
        await waitUntil("the refusal to be queued") { !self.items(context).isEmpty }

        let queued = try XCTUnwrap(items(context).first)
        XCTAssertFalse(queued.isOfflineReview, "a refusal is the question itself, not a review")
        XCTAssertEqual(queued.text, coffee)
        let reply = try XCTUnwrap(thread.turns.last { !$0.isUser })
        XCTAssertTrue(reply.text.contains("Not tried on the device: it asks to track something."),
                      reply.text)
        XCTAssertTrue(reply.text.contains("Queued for the bridge."))
    }

    // MARK: - The order the bridge sees

    /// **The whole scenario.** Offline: the coffee sentence is refused and queued, then a real
    /// lookup is answered and its review staged. Relaunch from disk. Back online: the bridge
    /// gets the queued request and then exactly one review turn, in that order.
    func testTheWholeScenarioReachesTheBridgeInOrderAfterARelaunch() async throws {
        let url = try onDiskStoreURL()
        let client = ReviewFakeClient()
        let offline = FakeOffline()
        offline.answers["When was I born?"] = born

        // ── Offline. `pollSleep` never returns for this coordinator, so the retry timer it
        //    arms cannot fire across the relaunch below and send the same message twice.
        do {
            let context = try store(at: url)
            let c = coordinator(client, offline, Reach(),
                                pollSleep: { _ in try? await Task.sleep(for: .seconds(600)) })
            let thread = JesseThread(mode: .ask)

            c.send(thread: thread, text: coffee, voice: false, context: context)
            await waitUntil("the coffee request to be queued and to fail against nothing") {
                self.items(context).first?.state == .failed
            }
            c.send(thread: thread, text: "When was I born?", voice: false, context: context)
            await waitUntil("the review to be staged") { self.items(context).count == 2 }

            let staged = items(context)
            XCTAssertEqual(staged[0].text, coffee, "the request was staged first")
            XCTAssertTrue(staged[1].isOfflineReview, "the review was staged second")
            XCTAssertTrue(client.accepted.isEmpty,
                          "nothing reached the bridge while it was away")
            try context.save()
        }

        // ── Relaunch: a second container over the same file, and a second coordinator.
        let context = try store(at: url)
        XCTAssertEqual(items(context).count, 2, "both survived the relaunch")
        client.online = true
        let reach = Reach()
        reach.state = .reachable
        let c = coordinator(client, offline, reach)

        c.recoverAfterNetworkReturned(context: context)
        await waitUntil("both messages to reach the bridge") { client.accepted.count == 2 }

        XCTAssertEqual(client.accepted.count, 2, "exactly one review turn, and no repeat")
        XCTAssertEqual(client.accepted[0], coffee,
                       "the request Jeremy typed goes first — it was staged first")
        XCTAssertTrue(client.accepted[1].hasPrefix(OfflineAnswerCarry.preamble),
                      "and then the review")
        XCTAssertTrue(client.accepted[1].contains("Q: When was I born?"))
        await waitUntil("the outbox to empty") { self.items(context).isEmpty }
    }

    /// **The path that dropped the carry (candidate 2).** A follow-up sent while reachability
    /// still reads `.unreachable` is routed on-device; the device cannot answer it, so
    /// `finishOnDevice` queues the question — and that queued item used to be the raw sentence
    /// with no record of the exchange it was about, so hosted Claude got "the reply makes no
    /// sense" with nothing to attach it to. The record precedes it now, because it was staged
    /// first and a conversation's outbox is delivered in order.
    func testAFollowUpQueuedOnTheDeviceNeverReachesTheBridgeBeforeItsReview() async throws {
        let context = try memoryContext()
        let client = ReviewFakeClient()
        let offline = FakeOffline()
        offline.answers["When was I born?"] = born
        let reach = Reach()
        let c = coordinator(client, offline, reach)

        let thread = JesseThread(mode: .ask)
        c.send(thread: thread, text: "When was I born?", voice: false, context: context)
        // Staged AND its first attempt spent against the absent bridge: the conversation reads
        // as running until that transmit settles, and a send on a running conversation is
        // refused, so waiting only for the item to exist would race it.
        await waitUntil("the review to be staged and to fail against nothing") {
            self.items(context).first?.state == .failed
        }

        // Still `.unreachable`, so this is routed on-device, abstains, and is queued.
        c.send(thread: thread, text: "Un, the reply makes no sense.", voice: false,
               context: context)
        await waitUntil("the follow-up to be queued") { self.items(context).count == 2 }

        client.online = true
        reach.state = .reachable
        c.recoverAfterNetworkReturned(context: context)
        await waitUntil("both to reach the bridge") { client.accepted.count == 2 }

        XCTAssertTrue(client.accepted[0].contains("Q: When was I born?"),
                      "the review of what the device did goes first: \(client.accepted)")
        XCTAssertEqual(client.accepted[1], "Un, the reply makes no sense.")
    }

    /// **Candidate 1**, the other path that dropped it: a replay (`onAck`) never composed the
    /// carry at all. It cannot drop a review now, because a review is not carried by a
    /// message — and the replayer's own conversation is brand new, so its item is always its
    /// own conversation's head and its ACK still reaches it.
    func testAReplaySendStillGetsItsOwnAckAndCarriesNothing() async throws {
        let context = try memoryContext()
        let client = ReviewFakeClient()
        client.online = true
        let reach = Reach()
        reach.state = .reachable
        let c = coordinator(client, FakeOffline(), reach)

        var acked: Bool?
        let thread = JesseThread(mode: .tell)
        c.send(thread: thread, text: "logged a coffee", voice: false, context: context) {
            acked = $0
        }
        await waitUntil("the ACK") { acked != nil }
        XCTAssertEqual(acked, true)
        XCTAssertEqual(client.accepted, ["logged a coffee"])
    }

    /// And the ordinary case is untouched: a conversation with nothing pending sends the
    /// message that was just typed, immediately, as it always did.
    func testAnOrdinarySendIsStillTransmittedAtOnce() async throws {
        let context = try memoryContext()
        let client = ReviewFakeClient()
        client.online = true
        let reach = Reach()
        reach.state = .reachable
        let c = coordinator(client, FakeOffline(), reach)

        let thread = JesseThread(mode: .ask)
        XCTAssertTrue(c.send(thread: thread, text: "hi there", voice: false, context: context))
        await waitUntil("the send to be accepted") { client.accepted == ["hi there"] }
        await waitUntil("the outbox to empty") { self.items(context).isEmpty }
    }
}
