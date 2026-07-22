import XCTest
@testable import JesseNetworking

/// The pure cross-device session reconciler: given the local session ids, the server
/// session list, the deletion tombstones, and the pending-local-delete ids, it decides
/// adopt / update / delete-local. No view host, no store, no server.
final class SessionReconcilerTests: XCTestCase {

    private func summary(_ id: String) -> SessionSummary {
        SessionSummary(sessionId: id, lastModified: 1_700_000_000, firstMessage: "hi \(id)", title: nil)
    }

    func testAdoptsUnknownSession() {
        let plan = SessionReconciler.plan(
            localSessionIds: [],
            sessions: [summary("s1")],
            tombstones: [],
            pendingDeletion: [])
        XCTAssertEqual(plan.adopt.map(\.sessionId), ["s1"])
        XCTAssertTrue(plan.update.isEmpty)
        XCTAssertTrue(plan.deleteLocalSessionIds.isEmpty)
    }

    func testMatchedIdProducesUpdateNotAdopt() {
        let plan = SessionReconciler.plan(
            localSessionIds: ["s1"],
            sessions: [summary("s1")],
            tombstones: [],
            pendingDeletion: [])
        XCTAssertTrue(plan.adopt.isEmpty)
        XCTAssertEqual(plan.update.map(\.sessionId), ["s1"])
    }

    func testTombstonedIdIsNotAdoptedAndDeletesLocal() {
        // Tombstoned + still listed by the bridge + held locally: never adopted/updated,
        // and deleted locally.
        let plan = SessionReconciler.plan(
            localSessionIds: ["s1"],
            sessions: [summary("s1")],
            tombstones: ["s1"],
            pendingDeletion: [])
        XCTAssertTrue(plan.adopt.isEmpty)
        XCTAssertTrue(plan.update.isEmpty)
        XCTAssertEqual(plan.deleteLocalSessionIds, ["s1"])
    }

    func testTombstonedUnknownIdIsNotAdoptedAndNotDeleted() {
        // A tombstone for an id we never held: nothing to adopt, nothing to delete.
        let plan = SessionReconciler.plan(
            localSessionIds: [],
            sessions: [summary("s1")],
            tombstones: ["s1"],
            pendingDeletion: [])
        XCTAssertTrue(plan.adopt.isEmpty)
        XCTAssertTrue(plan.deleteLocalSessionIds.isEmpty)
    }

    func testPendingLocalDeleteIsNotReAdopted() {
        // The resurrection guard: a session the user just deleted locally (remote delete
        // not drained yet) is still listed by the bridge, but must not be re-created.
        let plan = SessionReconciler.plan(
            localSessionIds: [],
            sessions: [summary("s1")],
            tombstones: [],
            pendingDeletion: ["s1"])
        XCTAssertTrue(plan.adopt.isEmpty)
        XCTAssertTrue(plan.update.isEmpty)
        XCTAssertTrue(plan.deleteLocalSessionIds.isEmpty)
    }

    func testMixedListPartitionsCorrectly() {
        let plan = SessionReconciler.plan(
            localSessionIds: ["known", "doomed"],
            sessions: [summary("known"), summary("fresh"), summary("pending")],
            tombstones: ["doomed"],
            pendingDeletion: ["pending"])
        XCTAssertEqual(plan.update.map(\.sessionId), ["known"])
        XCTAssertEqual(plan.adopt.map(\.sessionId), ["fresh"])
        XCTAssertEqual(plan.deleteLocalSessionIds, ["doomed"])
    }
}
