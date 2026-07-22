import XCTest
import SwiftData
@testable import Jesse
import JesseCore

/// Two-way conversation sync on iOS, driven through the real `RunCoordinator` + an
/// in-memory store + a fake client (no server): the phone adopts brand-new bridge
/// sessions, hydrates their transcripts on open with the seeding rule that stops it
/// re-importing its own turns, and honors cross-device deletion tombstones. The pure
/// adopt/update/delete decision itself is covered in the package
/// (`SessionReconcilerTests`); these assert the iOS wiring.
@MainActor
final class SessionSyncTests: XCTestCase {

    /// A fake bridge client that models `listSessions`, `hydrate`, and `send` for the sync
    /// paths. `transcripts[sid] = (turns, end)`: a `hydrate(after:)` returns the full turns
    /// when `after < end` (first sight) and nothing when `after >= end` (already at the
    /// tail), mirroring the real byte-cursor delta.
    @MainActor
    private final class FakeSyncClient: JesseClientProtocol {
        var scriptedSessions: SessionsResult = .notModified
        var transcripts: [String: (turns: [HydratedTurn], end: UInt64)] = [:]
        var sendResult: JesseSendResult = .reply(JesseReply(text: "", sessionId: nil), jobId: nil)
        private(set) var hydrateCalls: [(sid: String, after: UInt64)] = []

        func listSessions(etag: String?) async throws -> SessionsResult { scriptedSessions }

        func hydrate(sessionId: String, after: UInt64) async throws -> (turns: [HydratedTurn], nextOffset: UInt64) {
            hydrateCalls.append((sessionId, after))
            guard let t = transcripts[sessionId] else { throw JesseError.badResponse(404, "") }
            if after >= t.end { return ([], t.end) }
            return (t.turns, t.end)
        }

        func send(mode: JesseMode, text: String, sessionId: String?, voice: Bool,
                  instructions: String?, floorOverride: String?,
                  attachments: [JesseAttachment]) async throws -> JesseSendResult { sendResult }
        func result(jobId: String) async throws -> JesseResultState { .done(JesseReply(text: "", sessionId: nil)) }
        func cancelJob(jobId: String) async throws {}
        nonisolated func setFlags(sessionId: String, favorite: FlagWrite?, archived: FlagWrite?) async throws {}
        func stream(jobId: String) -> AsyncThrowingStream<JesseStreamEvent, Error> {
            AsyncThrowingStream { $0.finish() }
        }
    }

    @MainActor
    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: JesseThread.self, Turn.self, TurnAttachment.self, OutboxItem.self, OutboxAttachment.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return ModelContext(container)
    }

    private func scratchCursorStore() -> HydrationCursorStore {
        HydrationCursorStore(defaults: UserDefaults(suiteName: "SessionSyncTests.cursor.\(UUID().uuidString)")!)
    }

    private func scratchDeletionStore() -> PendingSessionDeletionStore {
        PendingSessionDeletionStore(defaults: UserDefaults(suiteName: "SessionSyncTests.del.\(UUID().uuidString)")!)
    }

    @MainActor
    private func makeCoordinator(_ fake: FakeSyncClient,
                                 cursor: HydrationCursorStore,
                                 deletion: PendingSessionDeletionStore) -> RunCoordinator {
        RunCoordinator(
            config: { JesseConfig(host: "studio", port: 8765, token: "tok") },
            makeClient: { _ in fake },
            sessionDeletionStore: deletion,
            hydrationCursorStore: cursor)
    }

    private func summary(_ id: String, title: String? = nil) -> SessionSummary {
        SessionSummary(sessionId: id, lastModified: 1_700_000_000, firstMessage: "hello \(id)", title: title)
    }

    private func turn(_ role: String, _ text: String) -> HydratedTurn {
        HydratedTurn(role: role, text: text, timestamp: nil)
    }

    @MainActor
    private func waitUntil(_ what: String, timeout: TimeInterval = 4, _ cond: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !cond() {
            if Date() > deadline { XCTFail("timed out: \(what)"); return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    private func threadCount(_ context: ModelContext) -> Int {
        ((try? context.fetch(FetchDescriptor<JesseThread>())) ?? []).count
    }

    private func thread(_ sid: String, in context: ModelContext) -> JesseThread? {
        ((try? context.fetch(FetchDescriptor<JesseThread>())) ?? []).first { $0.sessionId == sid }
    }

    // MARK: - Hydration seeding

    func testPhoneStartedThreadWithTurnsSeedsAndImportsNothing() async throws {
        let context = try makeContext()
        let cursor = scratchCursorStore()
        let fake = FakeSyncClient()
        // A phone-started thread: it already holds its own two turns and has no cursor.
        let t = JesseThread(mode: .ask); t.sessionId = "s1"
        let u = Turn(role: .user, text: "hi"); u.thread = t
        let j = Turn(role: .jesse, text: "hello"); j.thread = t
        context.insert(t); context.insert(u); context.insert(j)
        try context.save()
        // The server transcript for s1 already contains those turns (end at byte 500).
        fake.transcripts["s1"] = ([turn("user", "hi"), turn("assistant", "hello")], 500)

        let coordinator = makeCoordinator(fake, cursor: cursor, deletion: scratchDeletionStore())
        await coordinator.hydrateOnOpen(thread: t, context: context)

        XCTAssertEqual(t.turns.count, 2, "a phone-started thread must NOT re-import its own turns")
        XCTAssertEqual(cursor.offset("s1"), 500, "the cursor is seeded to the transcript end")
    }

    func testAdoptedStubImportsFullTranscriptThenOnlyDelta() async throws {
        let context = try makeContext()
        let cursor = scratchCursorStore()
        let fake = FakeSyncClient()
        // An adopted stub: session id, no local turns, no cursor.
        let t = JesseThread(mode: .ask); t.sessionId = "s2"
        context.insert(t)
        try context.save()
        fake.transcripts["s2"] = ([turn("user", "q1"), turn("assistant", "a1")], 300)

        let coordinator = makeCoordinator(fake, cursor: cursor, deletion: scratchDeletionStore())
        await coordinator.hydrateOnOpen(thread: t, context: context)

        XCTAssertEqual(t.turns.count, 2, "an adopted stub imports the full transcript")
        XCTAssertEqual(cursor.offset("s2"), 300)

        // A subsequent open with the cursor present imports only the delta (none here).
        await coordinator.hydrateOnOpen(thread: t, context: context)
        XCTAssertEqual(t.turns.count, 2, "a re-open past the cursor imports nothing new")
        XCTAssertEqual(fake.hydrateCalls.last?.after, 300, "the second hydrate asks only for the delta")
    }

    // MARK: - Adoption + delete via refresh

    func testRefreshAdoptsUnknownSession() async throws {
        let context = try makeContext()
        let fake = FakeSyncClient()
        fake.scriptedSessions = .sessions([summary("new", title: "From the Mac")], deleted: [], etag: "e1")

        let coordinator = makeCoordinator(fake, cursor: scratchCursorStore(), deletion: scratchDeletionStore())
        await coordinator.refreshSessions(context: context)

        let adopted = thread("new", in: context)
        XCTAssertNotNil(adopted, "an unknown bridge session is adopted as a local thread")
        XCTAssertEqual(adopted?.aiTitle, "From the Mac")
        XCTAssertTrue(adopted?.turns.isEmpty ?? false, "it is a stub, no transcript until opened")
    }

    func testRefreshWithTombstoneRemovesHeldThreadAndClearsCursor() async throws {
        let context = try makeContext()
        let cursor = scratchCursorStore()
        let fake = FakeSyncClient()
        let t = JesseThread(mode: .ask); t.sessionId = "doomed"
        let u = Turn(role: .user, text: "x"); u.thread = t
        context.insert(t); context.insert(u)
        try context.save()
        cursor.setOffset("doomed", 100)
        XCTAssertEqual(threadCount(context), 1)

        fake.scriptedSessions = .sessions([], deleted: [SessionTombstone(sessionId: "doomed", deletedMs: 1)], etag: "e1")
        let coordinator = makeCoordinator(fake, cursor: cursor, deletion: scratchDeletionStore())
        await coordinator.refreshSessions(context: context)

        XCTAssertEqual(threadCount(context), 0, "a tombstoned held thread is removed")
        XCTAssertNil(cursor.offset("doomed"), "its hydration cursor is cleared")
    }

    func testPendingDeleteSessionIsNotReAdopted() async throws {
        let context = try makeContext()
        let deletion = scratchDeletionStore()
        deletion.enqueue("pending")   // the user deleted it locally; remote delete not drained
        let fake = FakeSyncClient()
        // The bridge still lists it (delete hasn't propagated). It must NOT be re-created.
        fake.scriptedSessions = .sessions([summary("pending")], deleted: [], etag: "e1")

        let coordinator = makeCoordinator(fake, cursor: scratchCursorStore(), deletion: deletion)
        await coordinator.refreshSessions(context: context)

        XCTAssertNil(thread("pending", in: context), "a just-deleted session is never resurrected")
        XCTAssertEqual(threadCount(context), 0)
    }

    // MARK: - Delivery cursor advance (invariant)

    func testDeliveredReplyAdvancesCursorToEnd() async throws {
        let context = try makeContext()
        let cursor = scratchCursorStore()
        let fake = FakeSyncClient()
        // The reply carries the session id; the server transcript ends at byte 999.
        fake.sendResult = .reply(JesseReply(text: "an answer", sessionId: "s9"), jobId: nil)
        fake.transcripts["s9"] = ([turn("user", "ask"), turn("assistant", "an answer")], 999)

        let coordinator = makeCoordinator(fake, cursor: cursor, deletion: scratchDeletionStore())
        let t = JesseThread(mode: .ask)   // fresh phone thread, no session id yet
        context.insert(t)
        try context.save()

        coordinator.send(thread: t, text: "ask", voice: false, context: context)
        await waitUntil("the delivered reply's cursor to advance to the transcript end") {
            cursor.offset("s9") == 999
        }
        XCTAssertEqual(cursor.offset("s9"), 999,
                       "the phone advances its cursor past its own delivered reply so a later hydrate re-imports nothing")
    }
}
