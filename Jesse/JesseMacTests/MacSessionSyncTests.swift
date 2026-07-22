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
        let scriptedSessions: SessionsResult
        private let lock = NSLock()
        private var _deleted: [String] = []
        var deletedCalls: [String] { lock.withLock { _deleted } }
        nonisolated init(sessions: SessionsResult = .notModified) { self.scriptedSessions = sessions }

        nonisolated var config: JesseConfig { JesseConfig(host: "studio", port: 8765, token: "tok") }
        nonisolated func listSessions(since: UInt64?, etag: String?) async throws -> SessionsResult { scriptedSessions }
        nonisolated func setFlags(sessionId: String, favorite: FlagWrite?, archived: FlagWrite?) async throws {}
        nonisolated func deleteSession(_ sessionId: String) async throws {
            lock.withLock { _deleted.append(sessionId) }
        }

        // Inert surface, never exercised by the sync path.
        nonisolated func sendPrepared(_ request: JesseRequest) async throws -> JesseSendResult { throw JesseError.notConfigured }
        nonisolated func send(mode: JesseMode, text: String, sessionId: String?, voice: Bool,
                              instructions: String?, floorOverride: String?,
                              attachments: [JesseRequest.Attachment], requestId: String?) async throws -> JesseSendResult {
            throw JesseError.notConfigured
        }
        nonisolated func result(jobId: String) async throws -> JesseResultState { throw JesseError.notConfigured }
        nonisolated func stream(jobId: String) -> AsyncThrowingStream<JesseStreamEvent, Error> {
            AsyncThrowingStream { $0.finish() }
        }
        nonisolated func hydrate(sessionId: String, after: UInt64) async throws -> (turns: [HydratedTurn], nextOffset: UInt64) {
            throw JesseError.notConfigured
        }
        nonisolated func title(text: String, sessionId: String?) async -> String? { nil }
        nonisolated func cancelJob(jobId: String) async throws {}
        nonisolated func health() async throws -> BridgeHealth { BridgeHealth(version: nil) }
        nonisolated func fetchDietSnapshot(date: String?) async throws -> DietSnapshot { throw DietFetchError.notConfigured }
        nonisolated func fetchPrompts() async throws -> PromptDefaults { throw JesseError.notConfigured }
    }

    @MainActor
    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: JesseThread.self, Turn.self, TurnAttachment.self,
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

    private func summary(_ id: String) -> SessionSummary {
        SessionSummary(sessionId: id, lastModified: 1_700_000_000, firstMessage: "hi \(id)", title: nil)
    }

    private func threadCount(_ context: ModelContext) -> Int {
        ((try? context.fetch(FetchDescriptor<JesseThread>())) ?? []).count
    }
    private func thread(_ sid: String, in context: ModelContext) -> JesseThread? {
        ((try? context.fetch(FetchDescriptor<JesseThread>())) ?? []).first { $0.sessionId == sid }
    }

    func testAdoptsUnknownSession() async throws {
        let context = try makeContext()
        let fake = FakeBridgeClient(sessions: .sessions([summary("fromPhone")], deleted: [], etag: "e1"))
        let coordinator = makeCoordinator(fake, deletion: scratchDeletionStore())
        await coordinator.refreshSessions(context: context)
        XCTAssertNotNil(thread("fromPhone", in: context), "an unknown bridge session is adopted")
    }

    func testTombstoneRemovesHeldThreadAndClearsCursor() async throws {
        let context = try makeContext()
        let sid = "doomed-\(UUID().uuidString)"
        let t = JesseThread(mode: .ask); t.sessionId = sid
        context.insert(t)
        try context.save()
        MacCursorStore.setOffset(sid, 100)
        XCTAssertEqual(threadCount(context), 1)

        let fake = FakeBridgeClient(sessions: .sessions([], deleted: [SessionTombstone(sessionId: sid, deletedMs: 1)], etag: "e1"))
        let coordinator = makeCoordinator(fake, deletion: scratchDeletionStore())
        await coordinator.refreshSessions(context: context)

        XCTAssertEqual(threadCount(context), 0, "a tombstoned held thread is removed")
        XCTAssertEqual(MacCursorStore.offset(sid), 0, "its hydration cursor is cleared")
    }

    func testPendingDeleteSessionIsNotReAdopted() async throws {
        let context = try makeContext()
        let deletion = scratchDeletionStore()
        deletion.enqueue("pending")
        let fake = FakeBridgeClient(sessions: .sessions([summary("pending")], deleted: [], etag: "e1"))
        let coordinator = makeCoordinator(fake, deletion: deletion)
        await coordinator.refreshSessions(context: context)

        XCTAssertNil(thread("pending", in: context), "a just-deleted session is never resurrected")
        XCTAssertEqual(threadCount(context), 0)
    }
}
