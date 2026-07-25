import XCTest
@testable import JesseNetworking

/// The pure cross-device conversation reconciler: given the conversation ids held locally,
/// the server list, the deletion tombstones, and the pending-local-delete ids, it decides
/// adopt / update / delete-local. No view host, no store, no server.
///
/// Every rule here is the same rule the session-keyed reconciler enforced; only the KEY
/// changed, from an unstable Claude session id to the bridge's conversation id.
final class ConversationReconcilerTests: XCTestCase {

    private func summary(_ id: String) -> ConversationSummary {
        ConversationSummary(conversationId: id, sessionId: "sess-\(id)", sessionIds: ["sess-\(id)"],
                            lastModified: 1_700_000_000, firstMessage: "hi \(id)", title: nil)
    }

    func testAdoptsUnknownConversation() {
        let plan = ConversationReconciler.plan(
            heldConversationIds: [],
            conversations: [summary("c1")],
            tombstones: [],
            pendingDeletion: [])
        XCTAssertEqual(plan.adopt.map(\.conversationId), ["c1"])
        XCTAssertTrue(plan.update.isEmpty)
        XCTAssertTrue(plan.deleteLocalConversationIds.isEmpty)
    }

    func testMatchedIdProducesUpdateNotAdopt() {
        let plan = ConversationReconciler.plan(
            heldConversationIds: ["c1"],
            conversations: [summary("c1")],
            tombstones: [],
            pendingDeletion: [])
        XCTAssertTrue(plan.adopt.isEmpty)
        XCTAssertEqual(plan.update.map(\.conversationId), ["c1"])
    }

    func testTombstonedIdIsNotAdoptedAndDeletesLocal() {
        // Tombstoned + still listed by the bridge + held locally: never adopted/updated,
        // and deleted locally.
        let plan = ConversationReconciler.plan(
            heldConversationIds: ["c1"],
            conversations: [summary("c1")],
            tombstones: ["c1"],
            pendingDeletion: [])
        XCTAssertTrue(plan.adopt.isEmpty)
        XCTAssertTrue(plan.update.isEmpty)
        XCTAssertEqual(plan.deleteLocalConversationIds, ["c1"])
    }

    func testTombstonedUnknownIdIsNotAdoptedAndNotDeleted() {
        // A tombstone for an id we never held: nothing to adopt, nothing to delete. This
        // also covers the bridge reporting a tombstone from the legacy session key space
        // during the deprecation window: an id the client does not hold is simply inert.
        let plan = ConversationReconciler.plan(
            heldConversationIds: [],
            conversations: [summary("c1")],
            tombstones: ["c1"],
            pendingDeletion: [])
        XCTAssertTrue(plan.adopt.isEmpty)
        XCTAssertTrue(plan.deleteLocalConversationIds.isEmpty)
    }

    func testPendingLocalDeleteIsNotReAdopted() {
        // The resurrection guard: a conversation the user just deleted locally (remote
        // delete not drained yet) is still listed by the bridge, but must not be re-created.
        let plan = ConversationReconciler.plan(
            heldConversationIds: [],
            conversations: [summary("c1")],
            tombstones: [],
            pendingDeletion: ["c1"])
        XCTAssertTrue(plan.adopt.isEmpty)
        XCTAssertTrue(plan.update.isEmpty)
        XCTAssertTrue(plan.deleteLocalConversationIds.isEmpty)
    }

    func testMixedListPartitionsCorrectly() {
        let plan = ConversationReconciler.plan(
            heldConversationIds: ["known", "doomed"],
            conversations: [summary("known"), summary("fresh"), summary("pending")],
            tombstones: ["doomed"],
            pendingDeletion: ["pending"])
        XCTAssertEqual(plan.update.map(\.conversationId), ["known"])
        XCTAssertEqual(plan.adopt.map(\.conversationId), ["fresh"])
        XCTAssertEqual(plan.deleteLocalConversationIds, ["doomed"])
    }

    func testAConversationWithNoSessionYetIsStillAdoptable() {
        // A conversation registered at accept time has no bound session and so no
        // transcript. It must still be adoptable: that is exactly the row a second device
        // sees while the first device's opening turn is in flight, and refusing it would
        // hide the thread rather than duplicate it.
        let inFlight = ConversationSummary(conversationId: "c-new", sessionId: nil, sessionIds: [],
                                           lastModified: 1_700_000_000, firstMessage: nil,
                                           title: nil, registeredMs: 1_700_000_000_000)
        let plan = ConversationReconciler.plan(
            heldConversationIds: [],
            conversations: [inFlight],
            tombstones: [],
            pendingDeletion: [])
        XCTAssertEqual(plan.adopt.map(\.conversationId), ["c-new"])
        XCTAssertNil(plan.adopt[0].sessionId)
    }
}
