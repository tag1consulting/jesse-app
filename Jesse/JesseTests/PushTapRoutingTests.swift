import XCTest
import SwiftData
@testable import Jesse
import JesseCore
import JesseNetworking

/// Where a tapped notification lands.
///
/// The tap used to route on `job_id` alone, resolved through `RunCoordinator.inFlight` —
/// the turns THIS DEVICE started and has not yet settled. Two whole classes of
/// notification are never in that map: a **scheduled job**, which the phone never started,
/// and an **already-settled turn**, whose entry background delivery removes the moment it
/// writes the reply. Both silently landed on the thread list, because `openThread` ended
/// in a bare `guard let … else { return }`.
///
/// Every test here runs with an EMPTY in-flight map (`liveThreadID: nil`) except the one
/// that pins the fast path, because an empty in-flight map is precisely the defect.
@MainActor
final class PushTapRoutingTests: XCTestCase {

    /// A client that serves one conversation from `GET /jesse/conversations`, which is what
    /// lets the resolver's third branch adopt a conversation the phone has never seen.
    @MainActor
    private final class SessionsFakeClient: JesseClientProtocol {
        var remote: [ConversationSummary] = []
        private(set) var listCalls = 0

        func send(mode: JesseMode, text: String, sessionId: String?,
                  conversationId: String, voice: Bool,
                  instructions: String?, floorOverride: String?,
                  attachments: [JesseAttachment], requestId: UUID,
                  model: String?) async throws -> JesseSendResult {
            .running(jobId: "job-unused", conversationId: nil)
        }
        func result(jobId: String) async throws -> JesseResultState { .running }
        func cancelJob(jobId: String) async throws {}
        func stream(jobId: String) -> AsyncThrowingStream<JesseStreamEvent, Error> {
            AsyncThrowingStream { $0.finish() }
        }
        func notifyOnComplete(jobId: String) async throws {}
        func listConversations(etag: String?) async throws -> ConversationsResult {
            listCalls += 1
            return .conversations(remote, deleted: [], etag: nil)
        }
    }

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: JesseThread.self, Turn.self, OutboxItem.self, OutboxAttachment.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return ModelContext(container)
    }

    private func makeCoordinator(_ fake: SessionsFakeClient) -> RunCoordinator {
        RunCoordinator(
            config: { JesseConfig(host: "laptop", port: 8765, token: "tok") },
            makeClient: { _ in fake })
    }

    // MARK: - Parsing the payload

    /// Both routing keys come off the payload, trimmed, and a whitespace-only id is no id.
    func testTapCarriesBothIdsAndRejectsBlanks() {
        let both = PushTap(userInfo: ["job_id": "job-1", "conversation_id": "  CID-1  "])
        XCTAssertEqual(both?.jobId, "job-1")
        XCTAssertEqual(both?.conversationId, "CID-1")

        // An older bridge sends no conversation; a skipped scheduled run sends no job.
        XCTAssertEqual(PushTap(userInfo: ["job_id": "job-1"])?.conversationId, nil)
        XCTAssertEqual(PushTap(userInfo: ["conversation_id": "cid-1"])?.jobId, nil)

        // Neither id — an alert with nothing to route on. Not an error, just no tap.
        XCTAssertNil(PushTap(userInfo: [:]))
        XCTAssertNil(PushTap(userInfo: ["job_id": "   ", "conversation_id": ""]))
        XCTAssertNil(PushTap(userInfo: ["job_id": 42]))
    }

    // MARK: - The three-step chain

    /// STEP ONE stays first: it is the fastest path and it handles the live case. When the
    /// in-flight lookup answers, the conversation is not even consulted.
    func testTheInFlightJobStillWinsFirst() async throws {
        let context = try makeContext()
        let fake = SessionsFakeClient()
        let coordinator = makeCoordinator(fake)

        let live = JesseThread(mode: .ask)
        let other = JesseThread(mode: .ask)
        other.conversationId = "11111111-2222-3333-4444-555555555555"
        context.insert(live)
        context.insert(other)

        let tap = PushTap(jobId: "job-1", conversationId: other.conversationId)
        let resolved = await coordinator.thread(forTap: tap, liveThreadID: live.id, context: context)
        XCTAssertEqual(resolved?.id, live.id)
        XCTAssertEqual(fake.listCalls, 0, "the fast path never reaches the network")
    }

    /// THE REGRESSION. An already-settled turn has no in-flight entry — background delivery
    /// removed it when it wrote the reply — and tapping the banner afterwards used to land
    /// on the thread list. The conversation is right there in the store.
    func testASettledTurnRoutesByConversationWithAnEmptyInFlightMap() async throws {
        let context = try makeContext()
        let fake = SessionsFakeClient()
        let coordinator = makeCoordinator(fake)
        XCTAssertNil(coordinator.threadID(forJobId: "job-settled"),
                     "the in-flight map is empty — this is the case that used to fail")

        let thread = JesseThread(mode: .ask)
        thread.conversationId = "11111111-2222-3333-4444-555555555555"
        context.insert(thread)

        let tap = PushTap(jobId: "job-settled", conversationId: thread.conversationId)
        let resolved = await coordinator.thread(forTap: tap, liveThreadID: nil, context: context)
        XCTAssertEqual(resolved?.id, thread.id)
        XCTAssertEqual(fake.listCalls, 0, "a local hit does not need a sync")
    }

    /// The stored id is a canonical LOWERCASE uuid and the comparison is a plain `==`, so
    /// the incoming value is normalised before it is matched. `UUID.uuidString` is
    /// uppercase, which makes this the difference between matching and not.
    func testConversationMatchingIsCanonicallyLowercased() async throws {
        let context = try makeContext()
        let coordinator = makeCoordinator(SessionsFakeClient())

        let thread = JesseThread(mode: .ask)
        thread.conversationId = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        context.insert(thread)

        let tap = PushTap(jobId: nil, conversationId: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")
        let resolved = await coordinator.thread(forTap: tap, liveThreadID: nil, context: context)
        XCTAssertEqual(resolved?.id, thread.id)
    }

    /// STEP THREE, and the reason it is not optional polish. A scheduled run is a
    /// conversation this phone has never seen — the bridge mints a fresh one per fire and
    /// the phone was not involved — so there is nothing local to find. The sync adopts it,
    /// and the retry opens it.
    func testAScheduledConversationIsAdoptedByTheSyncThenOpens() async throws {
        let context = try makeContext()
        let fake = SessionsFakeClient()
        let cid = "99999999-8888-7777-6666-555555555555"
        fake.remote = [ConversationSummary(conversationId: cid, lastModified: 1,
                                           firstMessage: "morning routine")]
        let coordinator = makeCoordinator(fake)

        XCTAssertTrue(try context.fetch(FetchDescriptor<JesseThread>()).isEmpty,
                      "the phone has never seen this conversation")

        let tap = PushTap(jobId: "job-scheduled", conversationId: cid)
        let resolved = await coordinator.thread(forTap: tap, liveThreadID: nil, context: context)
        XCTAssertEqual(fake.listCalls, 1, "the local miss falls through to a sync")
        XCTAssertEqual(resolved?.conversationId, cid)
    }

    /// When nothing resolves the caller lands on the thread list — the pre-existing
    /// behaviour — but it must be a decision, not a silent fall-through. A push from a
    /// bridge that sends no conversation has only the fast path, and nothing else to try.
    func testAJobIdAloneWithNothingInFlightResolvesToNothing() async throws {
        let context = try makeContext()
        let fake = SessionsFakeClient()
        let coordinator = makeCoordinator(fake)

        let tap = PushTap(jobId: "job-gone", conversationId: nil)
        let resolved = await coordinator.thread(forTap: tap, liveThreadID: nil, context: context)
        XCTAssertNil(resolved)
        XCTAssertEqual(fake.listCalls, 0, "with no conversation there is nothing a sync could find")
    }

    /// A conversation the bridge does not know either: the sync runs, finds nothing, and
    /// the resolver gives up rather than hanging or inventing a thread.
    func testAnUnknownConversationGivesUpAfterTheSync() async throws {
        let context = try makeContext()
        let fake = SessionsFakeClient() // serves an empty list
        let coordinator = makeCoordinator(fake)

        let tap = PushTap(jobId: nil, conversationId: "00000000-0000-0000-0000-000000000000")
        let resolved = await coordinator.thread(forTap: tap, liveThreadID: nil, context: context)
        XCTAssertNil(resolved)
        XCTAssertEqual(fake.listCalls, 1, "it did try")
    }
}
