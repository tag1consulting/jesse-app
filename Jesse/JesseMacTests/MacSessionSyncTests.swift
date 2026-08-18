import XCTest
import SwiftData
@testable import Jesse_Mac
import JesseCore
import JesseNetworking

/// Two-way conversation sync on the Mac: `MacCoordinator.refreshSessions` routes through
/// the ONE shared `SessionReconciler` (adopt / update / delete-local), so it honors
/// cross-device deletion tombstones and the resurrection guard. Existing adoption and flag
/// convergence are covered in `MacFlagSyncTests`; the pure decision in the package's
/// `SessionReconcilerTests`.
@MainActor
final class MacSessionSyncTests: XCTestCase {

    private final class FakeBridgeClient: BridgeClientProtocol, @unchecked Sendable {
        let scriptedConversations: ConversationsResult
        private let lock = NSLock()
        private var _deleted: [String] = []
        var deletedCalls: [String] { lock.withLock { _deleted } }
        nonisolated init(conversations: ConversationsResult = .notModified) { self.scriptedConversations = conversations }

        nonisolated var config: JesseConfig { JesseConfig(host: "studio", port: 8765, token: "tok") }
        nonisolated func listConversations(since: UInt64?, etag: String?) async throws -> ConversationsResult { scriptedConversations }
        nonisolated func deleteConversation(_ conversationId: String) async throws {
            lock.withLock { _deleted.append(conversationId) }
        }

        // Inert surface, never exercised by the sync path.
        nonisolated func sendPrepared(_ request: JesseRequest) async throws -> JesseSendResult { throw JesseError.notConfigured }
        nonisolated func send(mode: JesseMode, text: String, sessionId: String?,
                              conversationId: String, voice: Bool,
                              instructions: String?, floorOverride: String?,
                              attachments: [JesseRequest.Attachment], requestId: String,
                              model: String?) async throws -> JesseSendResult {
            throw JesseError.notConfigured
        }
        nonisolated func result(jobId: String) async throws -> JesseResultState { throw JesseError.notConfigured }
        nonisolated func stream(jobId: String) -> AsyncThrowingStream<JesseStreamEvent, Error> {
            AsyncThrowingStream { $0.finish() }
        }
        nonisolated func hydrate(conversationId: String, after cursor: String?) async throws
            -> (turns: [HydratedTurn], nextCursor: String) {
            throw JesseError.notConfigured
        }
        nonisolated func title(text: String, conversationId: String?) async -> String? { nil }
        nonisolated func cancelJob(jobId: String) async throws {}
        nonisolated func health() async throws -> BridgeHealth { BridgeHealth(version: nil) }
        nonisolated func fetchDietSnapshot(date: String?) async throws -> DietSnapshot { throw DietFetchError.notConfigured }
        nonisolated func fetchPrompts() async throws -> PromptDefaults { throw JesseError.notConfigured }
    }

    @MainActor
    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: JesseThread.self, Turn.self, TurnAttachment.self, TurnArtifact.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return ModelContext(container)
    }

    private func scratchDeletionStore() -> PendingSessionDeletionStore {
        PendingSessionDeletionStore(defaults: UserDefaults(suiteName: "MacSessionSyncTests.\(UUID().uuidString)")!)
    }

    @MainActor
    private func makeCoordinator(_ fake: FakeBridgeClient,
                                 deletion: PendingSessionDeletionStore) -> MacCoordinator {
        MacCoordinator(configStore: MacConfigStore(config: JesseConfig(host: "studio", port: 8765, token: "tok")),
                       makeClient: { _ in fake },
                       sessionDeletionStore: deletion)
    }

    private func summary(_ id: String) -> ConversationSummary {
        ConversationSummary(conversationId: id, sessionId: "sess-\(id)", sessionIds: ["sess-\(id)"],
                            lastModified: 1_700_000_000, firstMessage: "hi \(id)", title: nil)
    }

    private func threadCount(_ context: ModelContext) -> Int {
        ((try? context.fetch(FetchDescriptor<JesseThread>())) ?? []).count
    }
    private func thread(_ sid: String, in context: ModelContext) -> JesseThread? {
        ((try? context.fetch(FetchDescriptor<JesseThread>())) ?? []).first { $0.conversationId == sid }
    }

    func testAdoptsUnknownSession() async throws {
        let context = try makeContext()
        let fake = FakeBridgeClient(conversations: .conversations([summary("fromPhone")], deleted: [], etag: "e1"))
        let coordinator = makeCoordinator(fake, deletion: scratchDeletionStore())
        await coordinator.refreshSessions(context: context)
        XCTAssertNotNil(thread("fromPhone", in: context), "an unknown bridge session is adopted")
    }

    func testTombstoneRemovesHeldThreadAndClearsCursor() async throws {
        let context = try makeContext()
        let cid = "doomed-\(UUID().uuidString)"
        let t = JesseThread(mode: .ask); t.conversationId = cid
        context.insert(t)
        try context.save()
        MacCursorStore.setCursor(cid, "0:100")
        XCTAssertEqual(threadCount(context), 1)

        let fake = FakeBridgeClient(conversations: .conversations(
            [], deleted: [ConversationTombstone(conversationId: cid, deletedMs: 1)], etag: "e1"))
        let coordinator = makeCoordinator(fake, deletion: scratchDeletionStore())
        await coordinator.refreshSessions(context: context)

        XCTAssertEqual(threadCount(context), 0, "a tombstoned held thread is removed")
        XCTAssertNil(MacCursorStore.cursor(cid), "its hydration cursor is cleared")
    }

    func testPendingDeleteSessionIsNotReAdopted() async throws {
        let context = try makeContext()
        let deletion = scratchDeletionStore()
        deletion.enqueue("pending")
        let fake = FakeBridgeClient(conversations: .conversations([summary("pending")], deleted: [], etag: "e1"))
        let coordinator = makeCoordinator(fake, deletion: deletion)
        await coordinator.refreshSessions(context: context)

        XCTAssertNil(thread("pending", in: context), "a just-deleted session is never resurrected")
        XCTAssertEqual(threadCount(context), 0)
    }

    // MARK: - Duplicate repair and the shared update rules

    func testMacMergesExistingDuplicateThreadsIntoOne() async throws {
        // The Mac's half of the repair pass: the same rules the phone applies, so the two
        // devices converge on one thread rather than each keeping its own copy.
        let context = try makeContext()
        let cid = "conv-dupe"
        let original = JesseThread(title: "Original", mode: .ask,
                                   createdAt: Date(timeIntervalSince1970: 1_000))
        original.conversationId = cid
        let a = Turn(role: .user, text: "q1", createdAt: Date(timeIntervalSince1970: 1_001))
        a.sourceKey = "s:0"; a.thread = original
        let dupe = JesseThread(title: "Duplicate", mode: .ask,
                               createdAt: Date(timeIntervalSince1970: 2_000))
        dupe.conversationId = cid
        let b = Turn(role: .user, text: "q2", createdAt: Date(timeIntervalSince1970: 2_001))
        b.sourceKey = "s:60"; b.thread = dupe
        for m in [original, dupe] { context.insert(m) }
        for t in [a, b] { context.insert(t) }
        try context.save()
        XCTAssertEqual(threadCount(context), 2)

        let fake = FakeBridgeClient(conversations: .conversations(
            [ConversationSummary(conversationId: cid, sessionId: "sess-1", sessionIds: ["sess-1"],
                                 lastModified: 1_700_000_000, firstMessage: "q1", title: "Merged")],
            deleted: [], etag: "e1"))
        let coordinator = makeCoordinator(fake, deletion: scratchDeletionStore())
        await coordinator.refreshSessions(context: context)

        XCTAssertEqual(threadCount(context), 1, "the duplicates collapsed")
        let survivor = try XCTUnwrap((try? context.fetch(FetchDescriptor<JesseThread>()))?.first)
        XCTAssertEqual(survivor.title, "Original", "the oldest thread wins")
        XCTAssertEqual(survivor.orderedTurns.map(\.text), ["q1", "q2"], "no turn was lost")
        XCTAssertEqual(survivor.sessionId, "sess-1", "the current session comes from the remote row")
    }

    func testMacAndPhoneApplyTheSameUpdateRulesToASharedConversation() async throws {
        // Both platforms now run the same UPDATE branch: refresh the title, adopt the CURRENT
        // session (which moves when the CLI forks), and advance the activity stamp only when
        // the remote is newer. The two used to diverge here, which was its own confusion.
        let context = try makeContext()
        let cid = "conv-shared"
        let held = JesseThread(mode: .ask, createdAt: Date(timeIntervalSince1970: 1_000))
        held.conversationId = cid
        held.sessionId = "sess-old"
        held.aiTitle = "stale"
        held.updatedAt = Date(timeIntervalSince1970: 1_000)
        context.insert(held); try context.save()

        let fake = FakeBridgeClient(conversations: .conversations(
            [ConversationSummary(conversationId: cid, sessionId: "sess-new",
                                 sessionIds: ["sess-old", "sess-new"],
                                 lastModified: 1_700_000_000, firstMessage: "hi",
                                 title: "fresh")],
            deleted: [], etag: "e1"))
        let coordinator = makeCoordinator(fake, deletion: scratchDeletionStore())
        await coordinator.refreshSessions(context: context)

        XCTAssertEqual(threadCount(context), 1, "updated, never duplicated")
        XCTAssertEqual(held.aiTitle, "fresh")
        XCTAssertEqual(held.sessionId, "sess-new", "the fork moved the current session")
        XCTAssertEqual(held.updatedAt.timeIntervalSince1970, 1_700_000_000, accuracy: 1)
    }
}
