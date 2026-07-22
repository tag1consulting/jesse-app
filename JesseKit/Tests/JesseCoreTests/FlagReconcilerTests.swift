import XCTest
import SwiftData
@testable import JesseCore

// The cross-device favorite/archive reconciler, driven by a fake `FlagSyncing` client
// and a real `JesseThread` — no view host, no server. Covers the four cases the sync
// contract rests on: server-newer adopts, local-newer pushes, equal is a no-op, and a
// thread with no session_id is skipped. Plus the independence of the two flags and the
// self-healing swallow of a failed push.

/// Records every `setFlags` call so a test can assert exactly what was pushed. `@unchecked
/// Sendable` behind a lock because the reconciler awaits it off the main actor.
private final class RecordingFlagClient: FlagSyncing, @unchecked Sendable {
    struct Call: Equatable {
        let sessionId: String
        let favorite: FlagWrite?
        let archived: FlagWrite?
    }
    private let lock = NSLock()
    private var _calls: [Call] = []
    /// When true, every `setFlags` throws — exercising the best-effort swallow.
    let shouldThrow: Bool

    init(shouldThrow: Bool = false) { self.shouldThrow = shouldThrow }

    func setFlags(sessionId: String, favorite: FlagWrite?, archived: FlagWrite?) async throws {
        lock.withLock {
            _calls.append(Call(sessionId: sessionId, favorite: favorite, archived: archived))
        }
        if shouldThrow { throw NSError(domain: "test", code: 1) }
    }

    var calls: [Call] {
        lock.withLock { _calls }
    }
}

// `@MainActor`: the tests drive a `JesseThread` (@Model, MainActor-isolated) through the
// MainActor `reconcile`, so the whole case runs on the main actor.
@MainActor
final class FlagReconcilerTests: XCTestCase {

    // MARK: - Pure per-flag decision

    func testDecideServerStrictlyNewerAdopts() {
        let d = FlagReconciler.decide(localValue: false, localMs: 100, serverValue: true, serverMs: 200)
        XCTAssertEqual(d, .adoptServer(value: true, updatedMs: 200))
    }

    func testDecideLocalStrictlyNewerPushes() {
        let d = FlagReconciler.decide(localValue: true, localMs: 300, serverValue: false, serverMs: 200)
        XCTAssertEqual(d, .pushLocal(FlagWrite(value: true, updatedMs: 300)))
    }

    func testDecideEqualClocksNoChange() {
        // Equal clocks never flip — the strict-greater rule matches the bridge, so a
        // tie converges to "already agreed" on both sides.
        let d = FlagReconciler.decide(localValue: true, localMs: 200, serverValue: false, serverMs: 200)
        XCTAssertEqual(d, .noChange)
    }

    // MARK: - Integrated reconcile

    private func makeThread(sessionId: String?) -> JesseThread {
        let t = JesseThread(title: "t", mode: .ask)
        t.sessionId = sessionId
        return t
    }

    func testServerNewerFavoriteAdoptedLocallyNoPush() async {
        let t = makeThread(sessionId: "s1")
        // Local unstarred at t=100; server starred at t=200 → server wins.
        t.setFavorite(false, now: Date(timeIntervalSince1970: 0.1))   // ms 100
        let client = RecordingFlagClient()
        let changed = await FlagReconciler.reconcile(
            thread: t,
            serverFavorite: true, serverFavoriteUpdatedMs: 200,
            serverArchived: false, serverArchivedUpdatedMs: 0,
            client: client)
        XCTAssertTrue(changed)
        XCTAssertTrue(t.isFavorite)
        XCTAssertEqual(t.favoriteUpdatedMs, 200, "adopts the server clock exactly")
        XCTAssertNotNil(t.favoritedAt, "display timestamp set when starred")
        XCTAssertTrue(client.calls.isEmpty, "adopting the server value pushes nothing")
    }

    func testLocalNewerFavoritePushedNotAdopted() async {
        let t = makeThread(sessionId: "s1")
        t.setFavorite(true, now: Date(timeIntervalSince1970: 0.3))    // ms 300
        let client = RecordingFlagClient()
        let changed = await FlagReconciler.reconcile(
            thread: t,
            serverFavorite: false, serverFavoriteUpdatedMs: 200,
            serverArchived: false, serverArchivedUpdatedMs: 0,
            client: client)
        XCTAssertFalse(changed, "local wins → no local mutation")
        XCTAssertTrue(t.isFavorite)
        XCTAssertEqual(client.calls.count, 1)
        XCTAssertEqual(client.calls.first?.sessionId, "s1")
        XCTAssertEqual(client.calls.first?.favorite, FlagWrite(value: true, updatedMs: 300))
        XCTAssertNil(client.calls.first?.archived, "only the changed flag is pushed")
    }

    func testEqualClocksBothFlagsNoOp() async {
        let t = makeThread(sessionId: "s1")
        t.setFavorite(true, now: Date(timeIntervalSince1970: 0.2))    // ms 200
        t.setArchived(true, now: Date(timeIntervalSince1970: 0.5))    // ms 500
        let client = RecordingFlagClient()
        let changed = await FlagReconciler.reconcile(
            thread: t,
            serverFavorite: true, serverFavoriteUpdatedMs: 200,
            serverArchived: true, serverArchivedUpdatedMs: 500,
            client: client)
        XCTAssertFalse(changed)
        XCTAssertTrue(client.calls.isEmpty, "converged clocks push nothing and mutate nothing")
    }

    func testNoSessionIdSkipped() async {
        let t = makeThread(sessionId: nil)
        t.setFavorite(true, now: Date(timeIntervalSince1970: 0.3))
        let client = RecordingFlagClient()
        let changed = await FlagReconciler.reconcile(
            thread: t,
            serverFavorite: false, serverFavoriteUpdatedMs: 999,
            serverArchived: false, serverArchivedUpdatedMs: 0,
            client: client)
        XCTAssertFalse(changed, "a purely-local thread never reconciles")
        XCTAssertTrue(client.calls.isEmpty)
        XCTAssertTrue(t.isFavorite, "and its local value is untouched")
    }

    func testEmptySessionIdSkipped() async {
        let t = makeThread(sessionId: "")
        let client = RecordingFlagClient()
        let changed = await FlagReconciler.reconcile(
            thread: t,
            serverFavorite: true, serverFavoriteUpdatedMs: 999,
            serverArchived: false, serverArchivedUpdatedMs: 0,
            client: client)
        XCTAssertFalse(changed)
        XCTAssertTrue(client.calls.isEmpty)
    }

    func testFlagsAreIndependentOnePushOneAdoptInOneCall() async {
        let t = makeThread(sessionId: "s1")
        // Local favorite newer (push), server archived newer (adopt): one setFlags call
        // carrying only favorite, and the archived value adopted locally.
        t.setFavorite(true, now: Date(timeIntervalSince1970: 0.4))    // ms 400
        t.setArchived(false, now: Date(timeIntervalSince1970: 0.1))   // ms 100
        let client = RecordingFlagClient()
        let changed = await FlagReconciler.reconcile(
            thread: t,
            serverFavorite: false, serverFavoriteUpdatedMs: 300,
            serverArchived: true, serverArchivedUpdatedMs: 500,
            client: client)
        XCTAssertTrue(changed, "the archived adoption mutated the thread")
        XCTAssertTrue(t.isArchived)
        XCTAssertEqual(t.archivedUpdatedMs, 500)
        XCTAssertEqual(client.calls.count, 1, "at most one push per reconcile")
        XCTAssertEqual(client.calls.first?.favorite, FlagWrite(value: true, updatedMs: 400))
        XCTAssertNil(client.calls.first?.archived, "archived was adopted, not pushed")
    }

    func testFailedPushIsSwallowedAndAdoptionStillApplies() async {
        let t = makeThread(sessionId: "s1")
        t.setFavorite(true, now: Date(timeIntervalSince1970: 0.4))    // ms 400 → push
        t.setArchived(false, now: Date(timeIntervalSince1970: 0.1))   // ms 100 → adopt
        let client = RecordingFlagClient(shouldThrow: true)
        // Must not throw out of reconcile: a push failure is best-effort and self-heals.
        let changed = await FlagReconciler.reconcile(
            thread: t,
            serverFavorite: false, serverFavoriteUpdatedMs: 300,
            serverArchived: true, serverArchivedUpdatedMs: 500,
            client: client)
        XCTAssertTrue(changed)
        XCTAssertTrue(t.isArchived, "the server-newer archived value is still adopted")
        XCTAssertEqual(client.calls.count, 1, "the push was attempted (and its throw swallowed)")
    }
}
