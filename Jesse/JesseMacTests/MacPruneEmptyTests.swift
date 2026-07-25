import XCTest
import SwiftData
@testable import Jesse_Mac
import JesseCore
import JesseNetworking

/// Abandoned ⌘N threads. `MacRootView.newChat` inserts AND SAVES an empty thread immediately,
/// so an unused new chat is a persisted empty row; they accumulate and read exactly like
/// duplicates in the sidebar. The phone already pruned these on its list appear; this is the
/// Mac's half, and the rule has to be narrow enough that it can never take a thread with any
/// history or one whose turn is in flight.
///
/// The prune itself lives in the view (it owns the `@Query` and the selection), so this
/// exercises the same predicate against a real store.
@MainActor
final class MacPruneEmptyTests: XCTestCase {

    /// The prune predicate, mirroring `MacRootView.pruneEmptyThreads`.
    private func isPrunable(_ t: JesseThread, running: UUID?) -> Bool {
        t.turns.isEmpty && (t.sessionId ?? "").isEmpty && t.registeredAt == nil && running != t.id
    }

    func testMacPruneEmptyRemovesAbandonedNewChat() throws {
        let context = try MacTestFixtures.context()
        // An abandoned ⌘N: inserted and saved, never used.
        let abandoned = JesseThread(mode: .ask)
        // A thread with history.
        let used = JesseThread(mode: .ask)
        let turn = Turn(role: .user, text: "hello"); turn.thread = used
        // A thread that has run (it has a session), even though its turns were cleared.
        let ran = JesseThread(mode: .ask)
        ran.sessionId = "sess-1"
        // A thread whose turn was ACCEPTED but whose transcript has not arrived: empty, no
        // session, yet absolutely not abandoned.
        let inFlight = JesseThread(mode: .ask)
        inFlight.registeredAt = Date()
        for t in [abandoned, used, ran, inFlight] { context.insert(t) }
        context.insert(turn)
        try context.save()

        let all = try context.fetch(FetchDescriptor<JesseThread>())
        let prunable = all.filter { isPrunable($0, running: nil) }

        XCTAssertEqual(prunable.map(\.id), [abandoned.id],
                       "only the never-used empty thread is prunable")
        for t in prunable { context.delete(t) }
        try context.save()
        XCTAssertEqual(try context.fetch(FetchDescriptor<JesseThread>()).count, 3)
    }

    func testAThreadWithATurnInFlightIsNeverPruned() throws {
        let context = try MacTestFixtures.context()
        // Empty and unsent, but its turn is RUNNING: the narrowest case the rule must respect,
        // because pruning it would delete the conversation the user is waiting on.
        let running = JesseThread(mode: .ask)
        context.insert(running)
        try context.save()

        XCTAssertFalse(isPrunable(running, running: running.id),
                       "the running thread is excluded even though it looks empty")
        XCTAssertTrue(isPrunable(running, running: UUID()),
                      "and it is prunable again once nothing is running on it")
    }
}
