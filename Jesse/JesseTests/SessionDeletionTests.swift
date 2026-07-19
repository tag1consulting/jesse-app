import XCTest
@testable import Jesse

/// Durable remote-session deletion: when the user deletes a thread we enqueue its
/// bridge `sessionId` into a persisted queue and a drainer calls
/// `DELETE /jesse/session/{id}` best-effort — clearing the tombstone on success
/// (incl. the bridge's idempotent 404) and leaving it for the next foreground on a
/// network failure. Driven through the existing `JesseClientProtocol` seam.
@MainActor
final class SessionDeletionTests: XCTestCase {

    /// A fake conforming to the existing client seam. Records `deleteSession` calls
    /// and can be flipped to throw (a network failure) so the retain-then-retry path
    /// is exercised without a server.
    @MainActor
    private final class DeleteFakeClient: JesseClientProtocol {
        var shouldThrow = false
        private(set) var deletedIds: [String] = []
        private(set) var deleteCalls = 0

        // Unused required methods (this seam only exercises deleteSession).
        func send(mode: JesseMode, text: String, sessionId: String?, voice: Bool,
                  instructions: String?, floorOverride: String?,
                  attachments: [JesseAttachment]) async throws -> JesseSendResult {
            .running(jobId: "unused")
        }
        func result(jobId: String) async throws -> JesseResultState { .running }
        func cancelJob(jobId: String) async throws {}
        func stream(jobId: String) -> AsyncThrowingStream<JesseStreamEvent, Error> {
            AsyncThrowingStream { $0.finish() }
        }

        // The method under test.
        func deleteSession(_ sessionId: String) async throws {
            deleteCalls += 1
            if shouldThrow { throw JesseError.connectionLost }
            deletedIds.append(sessionId)
        }
    }

    private func scratchStore() -> PendingSessionDeletionStore {
        // A throwaway suite per test so nothing touches the app's real defaults.
        let defaults = UserDefaults(suiteName: "session-del-test-\(UUID().uuidString)")!
        return PendingSessionDeletionStore(defaults: defaults)
    }

    // MARK: - Store

    func testEnqueueIsIdempotentBlankSafeAndPersists() {
        let defaults = UserDefaults(suiteName: "session-del-test-\(UUID().uuidString)")!
        let store = PendingSessionDeletionStore(defaults: defaults)
        XCTAssertTrue(store.pending.isEmpty)

        store.enqueue("sess-a")
        store.enqueue("sess-a")          // duplicate → ignored
        store.enqueue("   ")             // blank → ignored (no remote session)
        store.enqueue("sess-b")
        XCTAssertEqual(store.pending.map(\.sessionId), ["sess-a", "sess-b"],
                       "dedup by id, in enqueue order, blank dropped")

        // Persisted: a fresh store over the same defaults reloads the queue.
        let reloaded = PendingSessionDeletionStore(defaults: defaults)
        XCTAssertEqual(reloaded.pending.map(\.sessionId), ["sess-a", "sess-b"])

        store.remove("sess-a")
        XCTAssertEqual(store.pending.map(\.sessionId), ["sess-b"])
        store.remove("ghost")            // no-op
        XCTAssertEqual(store.pending.map(\.sessionId), ["sess-b"])
        store.remove("sess-b")
        XCTAssertTrue(store.pending.isEmpty)
    }

    // MARK: - Drainer: enqueue → drain → tombstone cleared

    @MainActor
    func testDrainDeletesAndClearsTombstoneOnSuccess() async {
        let store = scratchStore()
        let client = DeleteFakeClient()
        store.enqueue("sess-1")

        let drainer = SessionDeletionDrainer(store: store, makeClient: { client })
        await drainer.drain()

        XCTAssertEqual(client.deletedIds, ["sess-1"], "the remote delete was issued")
        XCTAssertTrue(store.pending.isEmpty, "tombstone cleared on success")
    }

    // MARK: - Drainer: failure → tombstone retained → later success

    @MainActor
    func testFailureRetainsTombstoneThenLaterSuccessClearsIt() async {
        let store = scratchStore()
        let client = DeleteFakeClient()
        client.shouldThrow = true
        store.enqueue("sess-x")

        let drainer = SessionDeletionDrainer(store: store, makeClient: { client })

        // Laptop asleep / offline: the delete throws, so the tombstone is kept.
        await drainer.drain()
        XCTAssertEqual(client.deleteCalls, 1)
        XCTAssertEqual(store.pending.map(\.sessionId), ["sess-x"],
                       "a network failure leaves the tombstone for next time")

        // Next foreground: the laptop is back, the drain succeeds, tombstone clears.
        client.shouldThrow = false
        await drainer.drain()
        XCTAssertEqual(client.deletedIds, ["sess-x"], "retried and deleted")
        XCTAssertTrue(store.pending.isEmpty, "cleared on the later success")
    }

    // MARK: - Drainer: one failing item never blocks the rest

    @MainActor
    func testDrainContinuesPastAFailingItem() async {
        let store = scratchStore()
        store.enqueue("good-1")
        store.enqueue("good-2")

        // A client that throws only for "good-1".
        final class SelectiveClient: JesseClientProtocol, @unchecked Sendable {
            private(set) var deleted: [String] = []
            func send(mode: JesseMode, text: String, sessionId: String?, voice: Bool,
                      instructions: String?, floorOverride: String?,
                      attachments: [JesseAttachment]) async throws -> JesseSendResult {
                .running(jobId: "unused")
            }
            func result(jobId: String) async throws -> JesseResultState { .running }
            func cancelJob(jobId: String) async throws {}
            func stream(jobId: String) -> AsyncThrowingStream<JesseStreamEvent, Error> {
                AsyncThrowingStream { $0.finish() }
            }
            func deleteSession(_ sessionId: String) async throws {
                if sessionId == "good-1" { throw JesseError.connectionLost }
                deleted.append(sessionId)
            }
        }
        let client = SelectiveClient()
        let drainer = SessionDeletionDrainer(store: store, makeClient: { client })
        await drainer.drain()

        XCTAssertEqual(client.deleted, ["good-2"], "the second item is still deleted")
        XCTAssertEqual(store.pending.map(\.sessionId), ["good-1"],
                       "only the failing item's tombstone remains")
    }
}
